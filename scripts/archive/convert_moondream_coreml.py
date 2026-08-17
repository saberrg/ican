#!/usr/bin/env python3
"""
convert_moondream_coreml.py

Converts Moondream 2B (vikhyatk/moondream2) to CoreML .mlpackage files
optimised for on-device inference on Apple Neural Engine (iOS 17+/18+).

Output models:
  moondream_vision.mlpackage      — vision encoder + projection (static, iOS 17)
  moondream_text.mlpackage        — text decoder with stateful KV cache (iOS 18)
  moondream_coord_encoder.mlpackage — Pointing coord encoder (static, iOS 17)
  moondream_coord_decoder.mlpackage — Pointing coord decoder (static, iOS 17)
  moondream_size_decoder.mlpackage  — Detection size decoder (static, iOS 17)

Usage (run with venv active, from ican/ root):
  PYTHONPATH=/path/to/moondream \\
  .venv-moondream/bin/python scripts/convert_moondream_coreml.py \\
      --output ios/Runner/EyePipeline/Models/Moondream

Requirements:
  pip install "coremltools==9.0" "torch==2.7.0" "transformers==5.5.4" \\
      "tokenizers==0.22.2" safetensors pillow accelerate huggingface_hub
"""

import argparse
import sys
import os
from pathlib import Path

# Ensure moondream repo is importable
_MOONDREAM_REPO = Path(__file__).resolve().parent.parent.parent / "moondream"
if _MOONDREAM_REPO.exists() and str(_MOONDREAM_REPO.parent) not in sys.path:
    sys.path.insert(0, str(_MOONDREAM_REPO.parent))

import torch
import torch.nn as nn
import numpy as np
import coremltools as ct
from coremltools.optimize.coreml import (
    OpPalettizerConfig,
    OptimizationConfig,
    palettize_weights,
)
from transformers import AutoModelForCausalLM

# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Moondream → CoreML converter")
    p.add_argument("--model",    default="vikhyatk/moondream2")
    p.add_argument("--revision", default="2025-06-21")
    p.add_argument("--output",   default="ios/Runner/EyePipeline/Models/Moondream")
    p.add_argument("--vision-only", action="store_true",
                   help="Only convert vision encoder (fast, good for testing)")
    p.add_argument("--skip-vision", action="store_true",
                   help="Skip vision encoder (already converted)")
    p.add_argument("--skip-prefill", action="store_true",
                   help="Skip prefill model (already converted)")
    return p.parse_args()

def log(msg): print(f"[convert] {msg}", flush=True)

# ── Quantization ──────────────────────────────────────────────────────────────

def palettize_4bit_bulk_8bit_output(mlmodel, name):
    """4-bit for transformer bulk, 8-bit for output/coordinate layers."""
    log(f"  Palettizing {name} (4-bit bulk, 8-bit output layers)...")
    sensitive = ["coord_decoder", "size_decoder", "lm_head", "coord_head", "size_head"]
    op_name_configs = {f"*{p}*": OpPalettizerConfig(nbits=8) for p in sensitive}
    config = OptimizationConfig(
        global_config=OpPalettizerConfig(nbits=4),
        op_name_configs=op_name_configs,
    )
    return palettize_weights(mlmodel, config=config)

def palettize_8bit(mlmodel, name):
    """8-bit for precision-critical models (coord/size heads)."""
    log(f"  Palettizing {name} (8-bit)...")
    config = OptimizationConfig(global_config=OpPalettizerConfig(nbits=8))
    return palettize_weights(mlmodel, config=config)

# ── 1. Vision Encoder + Projection ───────────────────────────────────────────

class VisionEncoderWrapper(nn.Module):
    """
    Wraps Moondream vision encoder + projection for a single 378×378 crop.

    Input:  image_crop (1, 3, 378, 378)  — normalised to [-1, 1]
    Output: image_embeddings (729, proj_out_dim)

    Uses hardcoded shape constants to avoid Python int() casts on traced
    tensors, which coremltools cannot lower to MIL ops.

    Shape constants for 2B model (enc_patch_size=14, crop_size=378):
      patch_dim   = 3 * 14 * 14 = 588
      num_patches = (378 // 14)^2 = 27^2 = 729
      enc_dim     = 1152
    """
    # --- hardcoded for 378×378 input, patch_size=14 ---
    PATCH_SIZE   = 14
    GRID         = 27      # 378 // 14
    NUM_PATCHES  = 729     # 27 * 27
    PATCH_DIM    = 588     # 3 * 14 * 14

    def __init__(self, md_model):
        super().__init__()
        self.vision = md_model.vision
        self.cfg    = md_model.config.vision

    def _create_patches(self, x: torch.Tensor) -> torch.Tensor:
        """Static-shape patch extraction — no dynamic int() casts."""
        P = self.PATCH_SIZE
        G = self.GRID
        # (1,3,378,378) → (1,3,G,P,G,P)
        x = x.reshape(1, 3, G, P, G, P)
        # → (1,G,G,3,P,P)
        x = x.permute(0, 2, 4, 1, 3, 5)
        # → (1, 729, 588)
        x = x.reshape(1, self.NUM_PATCHES, self.PATCH_DIM)
        return x

    def forward(self, image_crop: torch.Tensor) -> torch.Tensor:
        from moondream.torch.layers import attn, layer_norm, mlp
        from moondream.torch.vision import vision_projection

        w   = self.vision
        cfg = self.cfg

        # Patch embed
        x = self._create_patches(image_crop)       # (1, 729, PATCH_DIM)
        x = w.patch_emb(x)                         # (1, 729, enc_dim)
        x = x + w.pos_emb

        # All weights are float32 (wrapper.float() called before tracing)
        for block in w.blocks:
            x = x + attn(layer_norm(x, block.ln1), block.attn, n_heads=cfg.enc_n_heads)
            x = x + mlp(layer_norm(x, block.ln2), block.mlp)
        x = layer_norm(x, w.post_ln)               # (1, 729, enc_dim)

        global_features = x[0]                     # (729, enc_dim)

        # Reconstruct spatial map for projection
        n = cfg.enc_n_layers                        # 27
        reconstructed = global_features.view(n, n, cfg.enc_dim)

        img_emb = vision_projection(global_features, reconstructed, w, cfg)
        return img_emb                             # (729, proj_out_dim)


def convert_vision_encoder(md_model, output_dir: Path):
    log("Converting vision encoder + projection...")

    wrapper = VisionEncoderWrapper(md_model).eval().float()  # bfloat16→float32 for CoreML
    sample  = torch.zeros(1, 3, 378, 378)

    with torch.no_grad():
        out = wrapper(sample)
    log(f"  Forward pass OK — output shape: {tuple(out.shape)}")

    log("  Exporting with torch.export.export (handles dynamic ops)...")
    exported = torch.export.export(
        wrapper,
        args=(sample,),
        strict=False,
    )
    # Decompose from TRAINING → ATEN dialect (required by coremltools)
    exported = exported.run_decompositions({})

    log("  Converting to CoreML (iOS 17, Neural Engine)...")
    mlmodel = ct.convert(
        exported,
        inputs=[ct.TensorType(name="image_crop", shape=(1, 3, 378, 378))],
        outputs=[ct.TensorType(name="image_embeddings")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel = palettize_4bit_bulk_8bit_output(mlmodel, "VisionEncoder")

    out_path = output_dir / "moondream_vision.mlpackage"
    mlmodel.save(str(out_path))
    log(f"  Saved → {out_path}")
    return out_path

# ── 2. Text Decoder (Stateful KV Cache) ──────────────────────────────────────

class SingleStepTextDecoder(nn.Module):
    """
    Single-token decode step for CoreML stateful conversion.

    Runs one decode step and updates KV caches in-place (registered buffers
    → CoreML MLState). Uses standard SDPA (not flex_attention) for traceability.

    Inputs:
      token_embed  (1, 1, dim)          — current token embedding
      pos_id       (1,)  int            — current position index (0-based)
      attn_mask    (1, 1, 1, max_ctx)   — additive mask: 0=attend, -inf=masked
                                          caller sets valid positions to 0

    Output: logits (1, vocab_size)

    The caller maintains pos_id and updates attn_mask each step:
      attn_mask[0, 0, 0, pos] = 0.0  (unmask current and past positions)
    """
    def __init__(self, md_model):
        super().__init__()
        self.text = md_model.text
        self.cfg  = md_model.config.text

        # Register KV caches as buffers → CoreML MLState
        nh  = self.cfg.n_kv_heads
        ctx = self.cfg.max_context
        dh  = self.cfg.dim // self.cfg.n_heads
        for i in range(self.cfg.n_layers):
            self.register_buffer(f"k_cache_{i}", torch.zeros(1, nh, ctx, dh))
            self.register_buffer(f"v_cache_{i}", torch.zeros(1, nh, ctx, dh))

    @staticmethod
    def _apply_rope_static(
        x: torch.Tensor,        # (1, n_heads, 1, dh)
        freqs: torch.Tensor,    # (max_ctx, rot_dim/2, 2)
        pos: torch.Tensor,      # (1,) int
        rot_dim: int = 32,      # constant
    ) -> torch.Tensor:
        """
        Rotary embeddings without any .shape access — all dimensions are
        compile-time constants to avoid int() casts in the CoreML graph.
        """
        d_q    = rot_dim // 2          # 16
        x_rot  = x[..., :rot_dim]      # (1, n_heads, 1, 32)
        x_pass = x[..., rot_dim:]      # (1, n_heads, 1, dh-32)

        xq_r = x_rot[..., :d_q]       # (1, n_heads, 1, 16)
        xq_i = x_rot[..., d_q:]       # (1, n_heads, 1, 16)

        # Index freqs at current position — produces (1, rot_dim/2) tensors
        freqs_cos = freqs[pos, :, 0].unsqueeze(0).unsqueeze(0)  # (1, 1, 1, 16)
        freqs_sin = freqs[pos, :, 1].unsqueeze(0).unsqueeze(0)

        xq_out_r = xq_r * freqs_cos - xq_i * freqs_sin
        xq_out_i = xq_r * freqs_sin  + xq_i * freqs_cos
        xq_out   = torch.stack((xq_out_r, xq_out_i), dim=-1).flatten(-2)

        return torch.cat([xq_out.to(x.dtype), x_pass], dim=-1)

    def _ln(self, x: torch.Tensor, w) -> torch.Tensor:
        # All weights are float32 (wrapper.float() called before tracing)
        return torch.nn.functional.layer_norm(x, [self.cfg.dim], w.weight, w.bias)

    def _mlp(self, x: torch.Tensor, w) -> torch.Tensor:
        h = torch.nn.functional.gelu(w.fc1(x), approximate="tanh")
        return w.fc2(h)

    def _lm_head(self, x: torch.Tensor) -> torch.Tensor:
        h = x[:, -1, :]
        h = torch.nn.functional.layer_norm(
            h, [self.cfg.dim], self.text.post_ln.weight, self.text.post_ln.bias,
        )
        return self.text.lm_head(h)  # (1, vocab_size)

    def forward(
        self,
        token_embed: torch.Tensor,   # (1, 1, dim)  float32
        pos_id:      torch.Tensor,   # (1,)          int32
        attn_mask:   torch.Tensor,   # (1, 1, 1, max_ctx)  float32
    ) -> torch.Tensor:
        # All weights are float32 (wrapper.float() called before tracing) — no casting needed
        x   = token_embed
        dim = self.cfg.dim
        nh  = self.cfg.n_heads
        nkv = self.cfg.n_kv_heads
        dh  = dim // nh
        freqs = self.text.freqs_cis.float()

        for i, block in enumerate(self.text.blocks):
            k_buf = getattr(self, f"k_cache_{i}")
            v_buf = getattr(self, f"v_cache_{i}")

            l_in = self._ln(x, block.ln)
            qkv  = block.attn.qkv(l_in)
            q_dim, kv_dim = nh * dh, nkv * dh
            q, k, v = qkv.split([q_dim, kv_dim, kv_dim], dim=-1)

            q = q.view(1, 1, nh,  dh).transpose(1, 2)
            k = k.view(1, 1, nkv, dh).transpose(1, 2)
            v = v.view(1, 1, nkv, dh).transpose(1, 2)

            q = self._apply_rope_static(q, freqs, pos_id)
            k = self._apply_rope_static(k, freqs, pos_id)

            k_buf[:, :, pos_id[0], :] = k[:, :, 0, :]
            v_buf[:, :, pos_id[0], :] = v[:, :, 0, :]

            attn_out = torch.nn.functional.scaled_dot_product_attention(
                q, k_buf, v_buf, attn_mask=attn_mask,
            )
            attn_out = attn_out.transpose(1, 2).reshape(1, 1, dim)
            attn_out = block.attn.proj(attn_out)

            l_mlp = self._mlp(l_in, block.mlp)
            x = x + attn_out + l_mlp

        hidden = x                   # (1, 1, dim)
        logits = self._lm_head(x)   # (1, vocab_size)
        return logits, hidden


# ── 2b. Prefill Decoder (batch, seq_len=730, stateless) ──────────────────────

class MoondreamPrefill(nn.Module):
    """
    Batch prefill for Moondream — processes BOS + 729 image tokens in one shot.

    Input:  embeds (1, 730, dim)  — float32, BOS concat image embeddings
    Output: last_hidden (1, 1, dim)
            k_out_0 .. k_out_23   (1, n_kv_heads, 730, dh)  — one per layer
            v_out_0 .. v_out_23

    Stateless: Swift transfers these KV tensors into the decode model's MLState.
    Full mutual attention (no causal mask) matching Moondream's prefix attention.
    """
    PREFILL_LEN = 730   # 1 BOS + 729 image tokens — always fixed

    def __init__(self, md_model):
        super().__init__()
        self.text = md_model.text
        self.cfg  = md_model.config.text

    @staticmethod
    def _rope_batch(x, freqs):
        """Apply RoPE to a (1, n_heads, 730, dh) tensor at positions 0..729."""
        rot_dim = 32
        d_q     = 16
        x_rot   = x[..., :rot_dim]
        x_pass  = x[..., rot_dim:]
        xq_r    = x_rot[..., :d_q]
        xq_i    = x_rot[..., d_q:]
        # Static slice: positions 0..729 (no dynamic op)
        freqs_cos = freqs[:730, :, 0].unsqueeze(0).unsqueeze(0)  # (1,1,730,16)
        freqs_sin = freqs[:730, :, 1].unsqueeze(0).unsqueeze(0)
        out_r = xq_r * freqs_cos - xq_i * freqs_sin
        out_i = xq_r * freqs_sin + xq_i * freqs_cos
        out   = torch.stack((out_r, out_i), dim=-1).flatten(-2)
        return torch.cat([out.to(x.dtype), x_pass], dim=-1)

    def forward(self, embeds: torch.Tensor):   # (1, 730, dim)
        x   = embeds
        dim = self.cfg.dim
        nh  = self.cfg.n_heads
        nkv = self.cfg.n_kv_heads
        dh  = dim // nh
        freqs = self.text.freqs_cis.float()

        k_outs, v_outs = [], []

        for block in self.text.blocks:
            l_in = torch.nn.functional.layer_norm(
                x, [dim], block.ln.weight, block.ln.bias
            )
            qkv = block.attn.qkv(l_in)
            q_dim, kv_dim = nh * dh, nkv * dh
            q, k, v = qkv.split([q_dim, kv_dim, kv_dim], dim=-1)

            q = q.view(1, 730, nh,  dh).transpose(1, 2)
            k = k.view(1, 730, nkv, dh).transpose(1, 2)
            v = v.view(1, 730, nkv, dh).transpose(1, 2)

            q = self._rope_batch(q, freqs)
            k = self._rope_batch(k, freqs)

            k_outs.append(k)   # (1, nkv, 730, dh)
            v_outs.append(v)

            # Full mutual attention for the image prefix (no causal mask)
            attn_out = torch.nn.functional.scaled_dot_product_attention(q, k, v)
            attn_out = attn_out.transpose(1, 2).reshape(1, 730, dim)
            attn_out = block.attn.proj(attn_out)

            l_mlp = torch.nn.functional.gelu(block.mlp.fc1(l_in), approximate="tanh")
            l_mlp = block.mlp.fc2(l_mlp)
            x = x + attn_out + l_mlp

        last_hidden = x[:, -1:, :]          # (1, 1, dim)
        return tuple([last_hidden] + k_outs + v_outs)


def convert_prefill_model(md_model, output_dir: Path):
    log("Converting prefill model (batch 730 tokens, stateless)...")

    cfg = md_model.config.text
    dim = cfg.dim
    n   = cfg.n_layers
    nkv = cfg.n_kv_heads
    dh  = dim // cfg.n_heads

    wrapper = MoondreamPrefill(md_model).eval().float()  # bfloat16→float32 for CoreML
    sample  = torch.zeros(1, 730, dim)

    with torch.no_grad():
        out = wrapper(sample)
    log(f"  Forward OK — {len(out)} outputs, last_hidden {tuple(out[0].shape)}")

    log("  Tracing with torch.jit.trace...")
    traced = torch.jit.trace(wrapper, sample, strict=False)

    outputs = [ct.TensorType(name="last_hidden")]
    for i in range(n):
        outputs.append(ct.TensorType(name=f"k_out_{i}"))
    for i in range(n):
        outputs.append(ct.TensorType(name=f"v_out_{i}"))

    log("  Converting to CoreML (iOS 18 — needed for large model blob support)...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="embeds", shape=(1, 730, dim))],
        outputs=outputs,
        minimum_deployment_target=ct.target.iOS18,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel = palettize_4bit_bulk_8bit_output(mlmodel, "Prefill")

    out_path = output_dir / "moondream_prefill.mlpackage"
    mlmodel.save(str(out_path))
    log(f"  Saved → {out_path}")
    return out_path


# ── 2c. Token Embeddings Export ───────────────────────────────────────────────

def extract_token_embeddings(md_model, output_dir: Path):
    """
    Save BOS + template + common navigation object embeddings as float16 binary.
    Swift loads this to embed tokens without a separate CoreML model.
    """
    log("Extracting token embeddings...")

    # All unique token IDs needed — from config_md2.json templates
    template_ids = [
        50256,                              # BOS / EOS
        198, 24334, 1159, 25,               # caption normal: \\n\\nDetailed description:
        198, 16438, 8305, 25,               # caption short: \\n\\nShort description:
        198, 24361, 25,                     # query prefix: \\n\\nQuestion:
        198, 33706, 25,                     # query suffix: \\n\\nAnswer:
        198, 12727, 25, 628,                # point prefix/suffix
        198, 47504, 25,                     # detect prefix
    ]
    unique_template = sorted(set(template_ids))

    # Tokenize common navigation objects
    nav_objects = [
        " door", " person", " car", " bicycle", " motorcycle",
        " bus", " truck", " bench", " chair", " table",
        " stairs", " steps", " entrance", " exit", " sign",
        " traffic light", " stop sign", " wall", " floor", " ceiling",
        " curb", " ramp", " railing", " elevator", " escalator",
        " path", " road", " sidewalk", " crosswalk", " window",
    ]
    try:
        from tokenizers import Tokenizer
        tokenizer = Tokenizer.from_pretrained("moondream/starmie-v1")
        obj_token_map = {}
        for obj in nav_objects:
            ids = tokenizer.encode(obj).ids
            obj_token_map[obj.strip()] = ids
    except Exception as e:
        log(f"  Tokenizer unavailable ({e}) — skipping object tokens")
        obj_token_map = {}

    # All unique token IDs to embed
    all_obj_ids = [tid for ids in obj_token_map.values() for tid in ids]
    all_ids = sorted(set(unique_template + all_obj_ids))

    # Extract embeddings from wte (vocab_size × dim)
    wte = md_model.text.wte.detach().float()   # (51200, 2048)
    embeds = wte[all_ids]                        # (N, 2048)

    # Save binary (float16 for size)
    embeds_f16 = embeds.half().numpy()
    bin_path = output_dir / "moondream_token_embeddings.bin"
    embeds_f16.tofile(str(bin_path))
    log(f"  Saved embeddings: {len(all_ids)} tokens, {bin_path.stat().st_size // 1024} KB → {bin_path}")

    # Save JSON index: token_id → row index in binary
    import json
    meta = {
        "dim": 2048,
        "n_tokens": len(all_ids),
        "token_id_to_index": {str(tid): idx for idx, tid in enumerate(all_ids)},
        "templates": {
            "caption_normal": [198, 198, 24334, 1159, 25],
            "caption_short":  [198, 198, 16438, 8305, 25],
            "query_prefix":   [198, 198, 24361, 25],
            "query_suffix":   [198, 198, 33706, 25],
            "point_prefix":   [198, 198, 12727, 25],
            "point_suffix":   [628],
            "detect_prefix":  [198, 198, 47504, 25],
            "detect_suffix":  [628],
        },
        "objects": obj_token_map,
        "special": {"bos": 50256, "eos": 50256},
    }
    json_path = output_dir / "moondream_tokens.json"
    json_path.write_text(json.dumps(meta, indent=2))
    log(f"  Saved token metadata → {json_path}")


def convert_text_decoder(md_model, output_dir: Path):
    log("Converting text decoder (stateful KV cache, iOS 18)...")

    cfg = md_model.config.text
    dim = cfg.dim
    ctx = cfg.max_context
    nh  = cfg.n_kv_heads
    dh  = dim // cfg.n_heads
    n   = cfg.n_layers

    wrapper = SingleStepTextDecoder(md_model).eval().float()  # bfloat16→float32 for CoreML

    sample_embed = torch.zeros(1, 1, dim)
    sample_pos   = torch.tensor([0])
    # Additive mask: 0 = attend, -inf = ignore.  Start with all -inf, unmask pos 0.
    sample_mask  = torch.full((1, 1, 1, ctx), float("-inf"))
    sample_mask[0, 0, 0, 0] = 0.0

    with torch.no_grad():
        logits, hidden = wrapper(sample_embed, sample_pos, sample_mask)
    log(f"  Forward pass OK — logits {tuple(logits.shape)}, hidden {tuple(hidden.shape)}")

    # torch.jit.trace works here because:
    #   - all input shapes are fixed
    #   - data-dependent indexing (pos[0]) is fine for trace (no symbolic analysis)
    #   - no adaptive_avg_pool2d or other shape-dependent int() casts
    log("  Tracing with torch.jit.trace...")
    exported = torch.jit.trace(wrapper, (sample_embed, sample_pos, sample_mask), strict=False)

    states = []
    for i in range(n):
        states += [
            ct.StateType(wrapped_type=ct.TensorType(shape=(1, nh, ctx, dh)), name=f"k_cache_{i}"),
            ct.StateType(wrapped_type=ct.TensorType(shape=(1, nh, ctx, dh)), name=f"v_cache_{i}"),
        ]

    log("  Converting to CoreML (stateful iOS 18)...")
    mlmodel = ct.convert(
        exported,
        inputs=[
            ct.TensorType(name="token_embed", shape=(1, 1, dim)),
            ct.TensorType(name="pos_id",      shape=(1,), dtype=np.int32),
            ct.TensorType(name="attn_mask",   shape=(1, 1, 1, ctx)),
        ],
        outputs=[
            ct.TensorType(name="logits"),         # (1, vocab_size) — for token sampling
            ct.TensorType(name="hidden_state"),   # (1, 1, dim)     — for coord/size heads
        ],
        states=states,
        minimum_deployment_target=ct.target.iOS18,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel = palettize_4bit_bulk_8bit_output(mlmodel, "TextDecoder")

    out_path = output_dir / "moondream_text.mlpackage"
    mlmodel.save(str(out_path))
    log(f"  Saved → {out_path}")
    return out_path

# ── 3. Coordinate Head (Pointing) ────────────────────────────────────────────

class CoordEncoderWrapper(nn.Module):
    """coord (1,) → embedding (1, 1, dim)"""
    def __init__(self, region):
        super().__init__()
        self.region = region

    def forward(self, coord: torch.Tensor) -> torch.Tensor:
        from moondream.torch.region import encode_coordinate
        return encode_coordinate(coord.view(1, 1, 1), self.region)


class CoordDecoderWrapper(nn.Module):
    """hidden (1, 1, dim) → coord_logits (1, coord_out_dim)"""
    def __init__(self, region):
        super().__init__()
        self.region = region

    def forward(self, hidden: torch.Tensor) -> torch.Tensor:
        from moondream.torch.region import decode_coordinate
        return decode_coordinate(hidden, self.region)


def convert_coord_head(md_model, output_dir: Path):
    log("Converting coordinate (Pointing) heads...")
    dim = md_model.config.text.dim

    # Encoder
    enc = CoordEncoderWrapper(md_model.region).eval().float()
    s_coord = torch.tensor([0.5])
    with torch.no_grad(): enc(s_coord)
    tr_enc = torch.jit.trace(enc, s_coord, strict=False)
    ml_enc = ct.convert(
        tr_enc,
        inputs=[ct.TensorType(name="coord", shape=(1,))],
        outputs=[ct.TensorType(name="coord_embedding")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )
    ml_enc = palettize_8bit(ml_enc, "CoordEncoder")
    p = output_dir / "moondream_coord_encoder.mlpackage"
    ml_enc.save(str(p)); log(f"  Saved → {p}")

    # Decoder
    dec = CoordDecoderWrapper(md_model.region).eval().float()
    s_hidden = torch.zeros(1, 1, dim)
    with torch.no_grad(): dec(s_hidden)
    tr_dec = torch.jit.trace(dec, s_hidden, strict=False)
    ml_dec = ct.convert(
        tr_dec,
        inputs=[ct.TensorType(name="hidden", shape=(1, 1, dim))],
        outputs=[ct.TensorType(name="coord_logits")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )
    ml_dec = palettize_8bit(ml_dec, "CoordDecoder")
    p = output_dir / "moondream_coord_decoder.mlpackage"
    ml_dec.save(str(p)); log(f"  Saved → {p}")

# ── 4. Size Head (Detection) ──────────────────────────────────────────────────

class SizeDecoderWrapper(nn.Module):
    """hidden (1, 1, dim) → size_logits (2, size_out_dim)"""
    def __init__(self, region):
        super().__init__()
        self.region = region

    def forward(self, hidden: torch.Tensor) -> torch.Tensor:
        from moondream.torch.region import decode_size
        return decode_size(hidden, self.region)


def convert_size_head(md_model, output_dir: Path):
    log("Converting size (Detection) decoder...")
    dim = md_model.config.text.dim
    wrapper = SizeDecoderWrapper(md_model.region).eval().float()
    s = torch.zeros(1, 1, dim)
    with torch.no_grad(): wrapper(s)
    traced = torch.jit.trace(wrapper, s, strict=False)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="hidden", shape=(1, 1, dim))],
        outputs=[ct.TensorType(name="size_logits")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )
    ml = palettize_8bit(ml, "SizeDecoder")
    p = output_dir / "moondream_size_decoder.mlpackage"
    ml.save(str(p)); log(f"  Saved → {p}")

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    args = parse_args()
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    log(f"Loading {args.model} @ {args.revision} ...")
    log("  (~3.8 GB first run, cached on subsequent runs)")

    md_hf = AutoModelForCausalLM.from_pretrained(
        args.model,
        revision=args.revision,
        trust_remote_code=True,
        device_map="cpu",
        torch_dtype=torch.float16,  # half precision to keep peak RAM ~4 GB
    )
    md_model = md_hf.model
    md_model.use_flex_decoding = False   # disable flex_attention — use SDPA instead
    # Keep float16 — avoids 2× RAM spike (~4 GB vs ~8 GB). Layer norms cast locally.
    md_model.eval()

    log(f"Loaded. Config: text.dim={md_model.config.text.dim}, "
        f"n_layers={md_model.config.text.n_layers}, "
        f"vision.enc_dim={md_model.config.vision.enc_dim}")

    if not args.skip_vision:
        convert_vision_encoder(md_model, output_dir)
    else:
        log("Skipping vision encoder (--skip-vision)")

    if not args.vision_only:
        extract_token_embeddings(md_model, output_dir)
        if not args.skip_prefill:
            convert_prefill_model(md_model, output_dir)
        else:
            log("Skipping prefill model (--skip-prefill)")
        convert_text_decoder(md_model, output_dir)
        convert_coord_head(md_model, output_dir)
        convert_size_head(md_model, output_dir)

    log("")
    log("=== Conversion complete ===")
    log(f"Output: {output_dir.resolve()}")
    log("")
    log("Next: open Xcode → File → Add Files to 'Runner'")
    log(f"      select {output_dir.resolve()}/")
    log("      check 'Add to target: Runner'")



if __name__ == "__main__":
    main()

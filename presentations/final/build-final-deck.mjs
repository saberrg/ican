import pptxgen from 'pptxgenjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '../..');
const out = path.join(__dirname, 'iCAN_Final_Presentation_Group_5.pptx');
const appIcon = path.join(root, 'assets/ican-app-icon.png');

const pptx = new pptxgen();
pptx.layout = 'LAYOUT_WIDE';
pptx.author = 'Group 5 — ECE 441 Spring 2026';
pptx.company = 'Illinois Institute of Technology';
pptx.subject = 'iCAN assistive navigation system final presentation';
pptx.title = 'iCAN Final Presentation';
pptx.lang = 'en-US';
pptx.theme = {
  headFontFace: 'Aptos Display',
  bodyFontFace: 'Aptos',
  lang: 'en-US'
};
pptx.defineLayout({ name: 'WIDE', width: 13.333, height: 7.5 });
pptx.layout = 'WIDE';
pptx.margin = 0;
pptx.slideWidth = 13.333;
pptx.slideHeight = 7.5;
pptx.subject = 'iCAN Smart and Connected Embedded System Design';
pptx.company = 'Illinois Tech';
pptx.author = 'Ariel Nyamien, Aiden Verdin, Alex Stokrp, Saber Garibi';
pptx.lang = 'en-US';
pptx.defineSlideMaster({
  title: 'footer',
  background: { color: 'FFFFFF' },
  objects: [
    { line: { x: 0.55, y: 7.03, w: 12.2, h: 0, line: { color: 'D0D5DD', transparency: 55, width: 0.75 } } },
    { text: { text: 'iCAN · ECE 441 Spring 2026', options: { x: 0.65, y: 7.12, w: 3.3, h: 0.18, fontFace: 'Aptos', fontSize: 7.5, color: '667085', margin: 0 } } },
    { text: { text: 'Group 5', options: { x: 11.3, y: 7.12, w: 1.35, h: 0.18, fontFace: 'Aptos', fontSize: 7.5, color: '667085', margin: 0, align: 'right' } } }
  ],
  slideNumber: { x: 12.72, y: 7.12, color: '667085', fontSize: 7.5 }
});

const C = {
  bg: '06111F',
  bg2: '0B1730',
  ink: '101828',
  muted: '667085',
  slate: '475467',
  line: 'D0D5DD',
  white: 'FFFFFF',
  soft: 'F8FAFC',
  blue: '2563EB',
  cyan: '38BDF8',
  cyan2: '67E8F9',
  violet: '7C3AED',
  green: '22C55E',
  amber: 'F59E0B',
  red: 'EF4444',
  navy: '0F172A',
  card: 'FFFFFF'
};

const layout = { w: 13.333, h: 7.5 };
const slideNo = { x: 12.4, y: 7.1, w: 0.4, h: 0.15 };
let slideIndex = 0;

function addDarkBg(slide) {
  slide.background = { color: C.bg };
  slide.addShape(pptx.ShapeType.rect, { x: 0, y: 0, w: layout.w, h: layout.h, fill: { color: C.bg }, line: { color: C.bg } });
  slide.addShape(pptx.ShapeType.rect, { x: 0, y: 0, w: layout.w, h: 7.5, fill: { color: C.bg2, transparency: 25 }, line: { color: C.bg2, transparency: 100 } });
  slide.addShape(pptx.ShapeType.arc, { x: 8.85, y: -1.35, w: 5.0, h: 5.0, adjustPoint: 0.22, rotate: 15, line: { color: C.cyan, transparency: 64, width: 2 } });
  slide.addShape(pptx.ShapeType.arc, { x: 9.7, y: 0.15, w: 3.9, h: 3.9, adjustPoint: 0.25, rotate: 205, line: { color: C.violet, transparency: 68, width: 2 } });
  slide.addShape(pptx.ShapeType.line, { x: 0.65, y: 6.9, w: 11.95, h: 0, line: { color: C.cyan, transparency: 65, width: 1 } });
}

function addTitle(slide, title, subtitle = '', dark = false) {
  slide.addText(title, { x: 0.62, y: 0.42, w: 8.9, h: 0.45, fontSize: 25, bold: true, color: dark ? C.white : C.ink, margin: 0, fit: 'shrink' });
  if (subtitle) slide.addText(subtitle, { x: 0.64, y: 0.92, w: 8.8, h: 0.28, fontSize: 10.5, color: dark ? 'CBD5E1' : C.muted, margin: 0, fit: 'shrink' });
}

function tag(slide, text, x, y, color = C.cyan) {
  slide.addText(text, { x, y, w: 3.6, h: 0.25, fontSize: 9, bold: true, color, charSpace: 1.1, margin: 0, fit: 'shrink' });
}

function pill(slide, text, x, y, w, color = C.blue, textColor = C.white) {
  slide.addShape(pptx.ShapeType.roundRect, { x, y, w, h: 0.36, rectRadius: 0.06, fill: { color }, line: { color, transparency: 100 } });
  slide.addText(text, { x: x + 0.12, y: y + 0.09, w: w - 0.24, h: 0.15, fontSize: 8.2, bold: true, color: textColor, align: 'center', margin: 0, fit: 'shrink' });
}

function card(slide, x, y, w, h, title, body, accent = C.blue) {
  slide.addShape(pptx.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.08, fill: { color: C.card }, line: { color: 'E4E7EC', transparency: 20, width: 1 } });
  slide.addShape(pptx.ShapeType.rect, { x, y, w: 0.08, h, fill: { color: accent }, line: { color: accent, transparency: 100 } });
  slide.addText(title, { x: x + 0.28, y: y + 0.18, w: w - 0.5, h: 0.28, fontSize: 14, bold: true, color: C.ink, margin: 0, fit: 'shrink' });
  slide.addText(body, { x: x + 0.28, y: y + 0.55, w: w - 0.52, h: h - 0.7, fontSize: 9.5, color: C.slate, breakLine: false, margin: 0.01, fit: 'shrink', valign: 'top' });
}

function metric(slide, x, y, value, label, color = C.cyan) {
  slide.addText(value, { x, y, w: 1.8, h: 0.48, fontSize: 26, bold: true, color, margin: 0, align: 'center', fit: 'shrink' });
  slide.addText(label, { x: x - 0.15, y: y + 0.52, w: 2.1, h: 0.28, fontSize: 8.2, color: 'CBD5E1', margin: 0, align: 'center', fit: 'shrink' });
}

function addArrow(slide, x1, y1, x2, y2, color = C.blue) {
  slide.addShape(pptx.ShapeType.line, { x: x1, y: y1, w: x2 - x1, h: y2 - y1, line: { color, width: 2, beginArrowType: 'none', endArrowType: 'triangle' } });
}

function node(slide, x, y, w, h, title, body, color = C.blue, dark = false) {
  slide.addShape(pptx.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.08, fill: { color: dark ? '111827' : 'FFFFFF' }, line: { color, width: 1.2 } });
  slide.addText(title, { x: x + 0.14, y: y + 0.12, w: w - 0.28, h: 0.22, fontSize: 10.5, bold: true, color: dark ? C.white : C.ink, margin: 0, fit: 'shrink', align: 'center' });
  slide.addText(body, { x: x + 0.16, y: y + 0.44, w: w - 0.32, h: h - 0.54, fontSize: 7.8, color: dark ? 'CBD5E1' : C.slate, margin: 0, fit: 'shrink', align: 'center', valign: 'mid' });
}

function addSectionFooter(slide, dark = false) {
  slide.addText('iCAN · Group 5 · ECE 441 Spring 2026', { x: 0.65, y: 7.12, w: 4, h: 0.18, fontSize: 7.5, color: dark ? '94A3B8' : '667085', margin: 0 });
  slide.addText(String(++slideIndex), { x: 12.48, y: 7.12, w: 0.25, h: 0.18, fontSize: 7.5, color: dark ? '94A3B8' : '667085', margin: 0, align: 'right' });
}

function notes(slide, text) { slide.addNotes(text.split('\n').map(s => s.trim()).filter(Boolean)); }

// 1 Cover
{
  const s = pptx.addSlide(); addDarkBg(s); tag(s, 'FINAL DESIGN PROJECT', 0.78, 0.64);
  s.addText('iCAN', { x: 0.72, y: 1.22, w: 4.1, h: 0.92, fontSize: 56, bold: true, color: C.white, margin: 0 });
  s.addText('Assistive navigation system for safer independent mobility', { x: 0.82, y: 2.27, w: 7.1, h: 0.48, fontSize: 19, color: 'E2E8F0', margin: 0, fit: 'shrink' });
  s.addText('ECE 441 Spring 2026 · Smart and Connected Embedded System Design\nInstructor: Prof. Jafar Saniie', { x: 0.84, y: 3.05, w: 5.9, h: 0.45, fontSize: 10.5, color: 'CBD5E1', margin: 0, breakLine: false, fit: 'shrink' });
  ['Ariel Nyamien', 'Aiden Verdin', 'Alex Stokrp', 'Saber Garibi'].forEach((name, i) => pill(s, name, 0.82 + i * 1.75, 4.15, 1.45, i === 3 ? C.violet : C.blue));
  s.addImage({ path: appIcon, x: 9.15, y: 2.15, w: 2.25, h: 2.25, transparency: 0 });
  s.addText('CANE  +  EYE  +  APP', { x: 8.45, y: 4.75, w: 3.6, h: 0.3, fontSize: 13.5, bold: true, color: C.cyan2, margin: 0, align: 'center', charSpace: 1.2 });
  addSectionFooter(s, true); notes(s, 'Open with the project identity: iCAN is a connected assistive navigation ecosystem, not just a smart cane. Mention final deliverable context and team.');
}

// 2 Executive snapshot
{
  const s = pptx.addSlide('footer'); addTitle(s, 'Executive snapshot', 'What we built and why it matters');
  card(s, 0.72, 1.45, 3.65, 1.65, 'Problem', 'Traditional white canes detect ground-level obstacles well but miss head-height hazards, provide limited distance context, and do not integrate navigation or scene awareness.', C.red);
  card(s, 4.82, 1.45, 3.65, 1.65, 'Solution', 'iCAN combines directional obstacle sensing, haptic feedback, BLE telemetry, mobile accessibility UX, and an optional camera-based scene description layer.', C.blue);
  card(s, 8.92, 1.45, 3.65, 1.65, 'Impact', 'The system extends perception ahead of the user, preserves hands-free interaction, and moves compute-heavy AI to the phone for better latency, battery use, and upgradability.', C.green);
  node(s, 1.05, 4.05, 2.1, 0.86, 'Cane', 'LiDAR + ultrasonic + IMU + haptics', C.blue);
  addArrow(s, 3.35, 4.48, 4.45, 4.48, C.cyan);
  node(s, 4.55, 4.05, 2.1, 0.86, 'Eye', 'ESP32-S3 camera + BLE image stream', C.violet);
  addArrow(s, 6.85, 4.48, 7.95, 4.48, C.cyan);
  node(s, 8.05, 4.05, 2.1, 0.86, 'App', 'Flutter + BLE + TTS + AI vision', C.green);
  addArrow(s, 10.35, 4.48, 11.25, 4.48, C.cyan);
  node(s, 11.35, 4.05, 1.55, 0.86, 'User', 'Spatial audio + haptics', C.amber);
  s.addText('Design principle: keep immediate safety feedback local, use the phone for richer context.', { x: 1.2, y: 5.75, w: 10.9, h: 0.35, fontSize: 15, bold: true, color: C.ink, align: 'center', margin: 0, fit: 'shrink' });
  notes(s, 'Frame the system in one sentence: iCAN pairs immediate local safety feedback with phone-based intelligence.');
}

// 3 Problem
{
  const s = pptx.addSlide(); addDarkBg(s); addTitle(s, 'Navigation gaps we are targeting', 'The device focuses on hazards that are hard to perceive with a standard cane.', true);
  metric(s, 0.9, 1.7, '40%', 'blind individuals report head-height collisions', C.cyan2);
  metric(s, 3.15, 1.7, '43%', 'visually impaired users successfully complete street crossings', C.amber);
  metric(s, 5.4, 1.7, '2m+', 'target detection range ahead of the user', C.green);
  card(s, 8.05, 1.35, 4.15, 1.25, 'Why this is embedded systems work', 'The problem requires sensing, timing, power management, BLE communication, actuator feedback, and user-safe failure behavior — not just an app.', C.cyan);
  node(s, 1.0, 4.15, 2.25, 0.86, 'Head-height hazards', 'branches · signs · shelves · awnings', C.red, true);
  node(s, 3.7, 4.15, 2.25, 0.86, 'Distance ambiguity', 'near vs. far obstacles need different urgency', C.amber, true);
  node(s, 6.4, 4.15, 2.25, 0.86, 'Situational awareness', 'text · people · scene layout · landmarks', C.violet, true);
  node(s, 9.1, 4.15, 2.25, 0.86, 'Navigation load', 'turns must not mask obstacle alerts', C.green, true);
  addSectionFooter(s, true); notes(s, 'Use this slide to connect the human problem to the engineering requirements: sensing range, feedback encoding, and safety prioritization.');
}

// 4 System overview
{
  const s = pptx.addSlide('footer'); addTitle(s, 'System overview', 'Two embedded devices and one accessibility-first mobile client.');
  node(s, 0.8, 1.55, 2.25, 1.2, 'iCAN Cane', 'Arduino Nano ESP32\nLiDAR + ultrasonic\nIMU + haptics + GPS', C.blue);
  node(s, 0.8, 4.1, 2.25, 1.2, 'iCAN Eye', 'XIAO ESP32-S3 Sense\nOV2640 camera\nJPEG image stream', C.violet);
  node(s, 5.35, 2.7, 2.55, 1.25, 'Mobile App', 'Flutter client\nBLE control plane\nTTS + scene description', C.green);
  node(s, 10.25, 1.55, 2.1, 1.2, 'Local AI', 'Apple Vision\nCoreML depth/object\nOn-device fallback', C.cyan);
  node(s, 10.25, 4.1, 2.1, 1.2, 'Cloud AI', 'Gemini vision\nWhen online/user-selected', C.amber);
  addArrow(s, 3.2, 2.15, 5.1, 3.1, C.blue); addArrow(s, 3.2, 4.72, 5.1, 3.48, C.violet);
  addArrow(s, 8.1, 3.03, 10.0, 2.15, C.cyan); addArrow(s, 8.1, 3.58, 10.0, 4.72, C.amber);
  s.addText('BLE', { x: 3.75, y: 2.34, w: 0.55, h: 0.2, fontSize: 9, bold: true, color: C.blue, margin: 0 });
  s.addText('BLE image chunks', { x: 3.55, y: 4.1, w: 1.2, h: 0.2, fontSize: 9, bold: true, color: C.violet, margin: 0 });
  notes(s, 'Describe the split: cane handles real-time safety; eye captures scene imagery; app orchestrates BLE, speech, and AI backend selection.');
}

// 5 User flow
{
  const s = pptx.addSlide('footer'); addTitle(s, 'User interaction flow', 'Immediate haptics first; speech when richer context is needed.');
  const steps = [
    ['1', 'Walk normally', 'Cane continuously samples obstacle sensors and IMU.'],
    ['2', 'Detect hazard', 'Firmware maps obstacle side and distance into haptic urgency.'],
    ['3', 'Optional capture', 'User triggers iCAN Eye for a scene description.'],
    ['4', 'Phone interprets', 'App receives image data and chooses local/cloud AI path.'],
    ['5', 'Act safely', 'User receives directional vibration and spoken spatial context.']
  ];
  steps.forEach(([n,t,b],i)=>{
    const x=0.72+i*2.48;
    s.addShape(pptx.ShapeType.ellipse,{x,y:2.0,w:0.62,h:0.62,fill:{color:i<2?C.blue:i<4?C.violet:C.green},line:{color:'FFFFFF',width:1}});
    s.addText(n,{x:x+0.19,y:2.18,w:0.24,h:0.18,fontSize:10,bold:true,color:C.white,margin:0,align:'center'});
    if(i<4)addArrow(s,x+0.72,2.31,x+2.1,2.31,C.cyan);
    s.addText(t,{x:x-0.15,y:3.05,w:1.7,h:0.25,fontSize:13,bold:true,color:C.ink,margin:0,align:'center',fit:'shrink'});
    s.addText(b,{x:x-0.32,y:3.45,w:2.05,h:0.7,fontSize:8.6,color:C.slate,margin:0,align:'center',fit:'shrink'});
  });
  s.addShape(pptx.ShapeType.roundRect,{x:1.35,y:5.35,w:10.65,h:0.65,rectRadius:0.08,fill:{color:'EEF6FF'},line:{color:'B2DDFF'}});
  s.addText('Safety priority rule: local obstacle alerts must override slower navigation or AI descriptions.',{x:1.65,y:5.56,w:10,h:0.2,fontSize:13,bold:true,color:'1849A9',margin:0,align:'center',fit:'shrink'});
  notes(s, 'Walk through a realistic use case. Stress that the system is not trying to replace the cane; it extends feedback.');
}

// 6 Hardware
{
  const s = pptx.addSlide('footer'); addTitle(s, 'Hardware architecture', 'Sensors and actuators map directly to user-facing feedback.');
  card(s,0.65,1.35,3.05,1.28,'Cane controller','Arduino Nano ESP32 coordinates sensing, BLE telemetry, event detection, and haptic output.',C.blue);
  card(s,3.95,1.35,3.05,1.28,'Obstacle sensing','TF-Luna/ToF and ultrasonic sensing provide near/far and head/waist-level obstacle coverage.',C.cyan);
  card(s,7.25,1.35,3.05,1.28,'Motion + health','LSM6DSOX IMU supports fall detection/orientation; pulse and battery telemetry support monitoring.',C.green);
  card(s,10.55,1.35,2.1,1.28,'Feedback','DRV2605L and vibration motors encode direction and urgency through touch.',C.amber);
  node(s,1.1,4.0,1.5,0.75,'LiDAR/ToF','head-height + spatial grid',C.cyan);
  node(s,3.0,4.0,1.5,0.75,'Ultrasonic','lower obstacle zones',C.cyan);
  node(s,4.9,4.0,1.5,0.75,'IMU','yaw + fall events',C.green);
  node(s,6.8,4.0,1.5,0.75,'GPS','location + guided nav',C.green);
  node(s,8.7,4.0,1.5,0.75,'BLE','app telemetry',C.blue);
  node(s,10.6,4.0,1.5,0.75,'Haptics','left/right/top motors',C.amber);
  addArrow(s,2.62,4.37,2.95,4.37,C.line); addArrow(s,4.52,4.37,4.85,4.37,C.line); addArrow(s,6.42,4.37,6.75,4.37,C.line); addArrow(s,8.32,4.37,8.65,4.37,C.line); addArrow(s,10.22,4.37,10.55,4.37,C.line);
  s.addText('BOM highlights: Arduino Nano ESP32, XIAO ESP32-S3 Sense, TF-Luna/ToF, ultrasonic sensors, LSM6DSOX, DRV2605L, vibration motors, GPS, Li-Po batteries.',{x:0.92,y:5.85,w:11.5,h:0.32,fontSize:10.5,color:C.slate,align:'center',margin:0,fit:'shrink'});
  notes(s, 'Covers the report requirement for hardware, sensors, actuators, and system constraints.');
}

// 7 Sensing and haptics
{
  const s = pptx.addSlide(); addDarkBg(s); addTitle(s, 'Obstacle detection → haptic language', 'The user should feel direction, distance, and urgency without looking at a screen.', true);
  node(s,0.85,1.55,2.15,0.92,'Left/right ultrasonics','waist-level obstacles\nside-specific alerts',C.cyan,true);
  node(s,3.55,1.55,2.15,0.92,'Top LiDAR/ToF','head-height hazards\nbranches/signs/awnings',C.cyan,true);
  node(s,6.25,1.55,2.15,0.92,'IMU sweep filter','reduces false positives\nfrom natural cane motion',C.green,true);
  node(s,8.95,1.55,2.15,0.92,'Haptic driver','distance-scaled\npulse/intensity patterns',C.amber,true);
  ['2–4 m: intermittent pulse','1–2 m: continuous vibration','<1 m: strong vibration'].forEach((t,i)=>{
    s.addShape(pptx.ShapeType.roundRect,{x:2.1+i*3.05,y:4.05,w:2.55,h:0.62,rectRadius:0.08,fill:{color:i===0?'123D2A':i===1?'4A3000':'4A1515'},line:{color:i===0?C.green:i===1?C.amber:C.red,width:1}});
    s.addText(t,{x:2.25+i*3.05,y:4.25,w:2.25,h:0.18,fontSize:10,bold:true,color:C.white,margin:0,align:'center',fit:'shrink'});
  });
  s.addText('Feedback rule: the closest safety event wins over navigation guidance.',{x:2.0,y:5.65,w:9.2,h:0.28,fontSize:15,bold:true,color:C.cyan2,align:'center',margin:0,fit:'shrink'});
  addSectionFooter(s,true); notes(s,'Explain the tactile language. Distance and side are turned into vibration patterns, not text.');
}

// 8 Firmware
{
  const s = pptx.addSlide('footer'); addTitle(s, 'Cane firmware structure', 'Modular firmware keeps sensing, events, power, and feedback testable.');
  node(s,0.85,1.45,2.0,0.9,'Sensor layer','LiDAR · ultrasonic · IMU · pulse · GPS · battery',C.cyan);
  node(s,3.25,1.45,2.0,0.9,'Event detection','obstacle side · fall flag · low battery · sensor health',C.green);
  node(s,5.65,1.45,2.0,0.9,'State manager','normal · low power · emergency · sleep',C.blue);
  node(s,8.05,1.45,2.0,0.9,'Response layer','haptic · LED · buzzer · BLE notify',C.amber);
  node(s,10.45,1.45,2.0,0.9,'App telemetry','battery % · BPM · yaw · GPS · status',C.violet);
  for(let i=0;i<4;i++) addArrow(s,2.9+i*2.4,1.9,3.2+i*2.4,1.9,C.line);
  card(s,0.95,3.35,3.35,1.35,'Power management','Firmware documentation reports sleep modes that reduce idle draw from always-active behavior into staged low-power states.',C.green);
  card(s,4.95,3.35,3.35,1.35,'Safety behavior','Fall alert logic avoids indefinite buzzer activation and caps emergency behavior to prevent battery drain.',C.red);
  card(s,8.95,3.35,3.0,1.35,'Protocol discipline','A shared BLE protocol file mirrors packet fields in C++ firmware and Dart app code to avoid mismatch bugs.',C.blue);
  s.addText('Evidence source: firmware/protosmart_cane STATUS_REPORT, DEPLOYMENT_CHECKLIST, and protocol/ble_protocol.yaml.',{x:1.1,y:5.55,w:11.0,h:0.25,fontSize:9.4,color:C.muted,margin:0,align:'center',fit:'shrink'});
  notes(s,'This slide maps directly to software/hardware integration and original code contributions.');
}

// 9 Eye
{
  const s = pptx.addSlide('footer'); addTitle(s, 'iCAN Eye: scene awareness pipeline', 'Camera hardware captures the world; the phone turns it into speech.');
  node(s,0.85,2.3,1.9,0.86,'ESP32-S3 Eye','OV2640 capture\nbutton trigger',C.violet);
  addArrow(s,2.95,2.73,4.0,2.73,C.violet);
  node(s,4.1,2.3,1.9,0.86,'BLE stream','JPEG chunks\nsequence numbers',C.violet);
  addArrow(s,6.2,2.73,7.25,2.73,C.cyan);
  node(s,7.35,2.3,1.9,0.86,'Phone vision','Apple Vision\nDepth + objects + OCR',C.cyan);
  addArrow(s,9.45,2.73,10.5,2.73,C.green);
  node(s,10.6,2.3,1.9,0.86,'Speech','4–6 sentence\nspatial description',C.green);
  card(s,0.9,4.25,3.25,1.28,'Layer 1 perception','OCR, scene classification, human detection, depth estimation, and object boxes run as structured perception.',C.cyan);
  card(s,4.75,4.25,3.25,1.28,'Layer 2 understanding','A VLM backend adds holistic image interpretation when local model or cloud mode is available.',C.violet);
  card(s,8.6,4.25,3.25,1.28,'Layer 3 speech synthesis','The app converts perception into short, practical, clock-position guidance.',C.green);
  notes(s,'This is the “wow” software slide: phone-side AI makes the embedded camera useful without forcing the ESP32 to run heavy models.');
}

// 10 Mobile app
{
  const s = pptx.addSlide(); addDarkBg(s); addTitle(s, 'Mobile app architecture', 'Flutter app as the accessible command center.', true);
  s.addImage({ path: appIcon, x: 0.92, y: 1.55, w: 1.4, h: 1.4 });
  card(s,2.9,1.25,2.85,1.2,'Accessibility-first UI','WCAG AAA-oriented theme, Semantics wrappers, large controls, VoiceOver/TalkBack design.',C.green);
  card(s,6.1,1.25,2.85,1.2,'BLE services','Dual-device connection management, image reassembly, telemetry streams, saved device IDs.',C.blue);
  card(s,9.3,1.25,2.85,1.2,'Speech loop','TTS output, voice-command direction, and scene-description history for repeatable feedback.',C.violet);
  node(s,1.05,4.15,1.95,0.78,'HomeViewModel','state orchestration',C.green,true);
  node(s,3.55,4.15,1.95,0.78,'BleService','scan/connect/packets',C.blue,true);
  node(s,6.05,4.15,1.95,0.78,'SceneService','backend selection',C.violet,true);
  node(s,8.55,4.15,1.95,0.78,'VisionChannel','Swift/CoreML bridge',C.cyan,true);
  node(s,11.05,4.15,1.25,0.78,'TTS','audio output',C.amber,true);
  [3.05,5.55,8.05,10.55].forEach(x=>addArrow(s,x,4.54,x+0.45,4.54,C.cyan));
  s.addText('Tech stack: Dart/Flutter, Provider MVVM, GoRouter, flutter_blue_plus, CoreML/Vision Swift channels, Gemini fallback.',{x:1.15,y:5.85,w:10.9,h:0.28,fontSize:10.5,color:'CBD5E1',align:'center',margin:0,fit:'shrink'});
  addSectionFooter(s,true); notes(s,'Ground this in the actual repo QA technical briefing.');
}

// 11 BLE protocol
{
  const s = pptx.addSlide('footer'); addTitle(s, 'BLE protocol and data model', 'A shared protocol keeps firmware and app behavior aligned.');
  card(s,0.75,1.35,3.2,1.38,'Cane service','Navigation commands, obstacle alerts, IMU telemetry, cane status, GPS data.',C.blue);
  card(s,5.05,1.35,3.2,1.38,'Eye service','Instant text, JPEG image stream, capture/profile/status commands.',C.violet);
  card(s,9.35,1.35,3.0,1.38,'Packet discipline','Little-endian telemetry, explicit fields, and documented image sequence headers.',C.green);
  node(s,1.0,4.05,1.55,0.78,'App → Cane','NAV_LEFT\nNAV_RIGHT\nSTOP',C.blue);
  node(s,3.15,4.05,1.55,0.78,'Cane → App','obstacle\nfall flag\nbattery',C.green);
  node(s,5.3,4.05,1.55,0.78,'App → Eye','CAPTURE\nLIVE_START\nPROFILE',C.violet);
  node(s,7.45,4.05,1.55,0.78,'Eye → App','text\nimage chunks',C.violet);
  node(s,9.6,4.05,1.55,0.78,'App → User','speech\nalerts\nhaptics',C.amber);
  s.addText('Single source of truth: protocol/ble_protocol.yaml mirrors firmware/shared/ble_protocol.h and lib/protocol/ble_protocol.dart.',{x:1.1,y:5.75,w:11.1,h:0.24,fontSize:9.5,color:C.muted,margin:0,align:'center',fit:'shrink'});
  notes(s,'Use this as the systems engineering proof: packet names, directions, and payload fields exist in the repo.');
}

// 12 Power and packaging
{
  const s = pptx.addSlide('footer'); addTitle(s, 'Power, packaging, and constraints', 'The design is constrained by weight, runtime, weather, and user comfort.');
  card(s,0.8,1.3,2.75,1.25,'Runtime target','Prior deck target: 8–10 hour operating goal; firmware emphasizes staged power modes and battery telemetry.',C.green);
  card(s,3.95,1.3,2.75,1.25,'Physical layout','Handle houses haptic motors; sensors mount below/top of handle with wiring strain relief and shock mounting.',C.blue);
  card(s,7.1,1.3,2.75,1.25,'Weather & durability','Prior design target includes IP65-style considerations: gaskets, venting, connectors, and robust mounting.',C.cyan);
  card(s,10.25,1.3,2.25,1.25,'Safety','Failsafe behavior: obstacle alerts remain local; cloud AI is optional, not required for basic safety.',C.red);
  s.addShape(pptx.ShapeType.rect,{x:1.25,y:4.25,w:10.75,h:0.18,fill:{color:'E4E7EC'},line:{color:'E4E7EC'}});
  const modes=[['Active','100% duty',C.red],['Use case','mixed sensing',C.blue],['Low power','reduced draw',C.green],['Emergency','bounded alert',C.amber]];
  modes.forEach(([a,b,c],i)=>{ const x=1.35+i*2.75; s.addShape(pptx.ShapeType.ellipse,{x,y:3.93,w:0.82,h:0.82,fill:{color:c},line:{color:'FFFFFF',width:1}}); s.addText(a,{x:x-0.45,y:4.95,w:1.7,h:0.22,fontSize:10,bold:true,color:C.ink,align:'center',margin:0,fit:'shrink'}); s.addText(b,{x:x-0.5,y:5.25,w:1.85,h:0.2,fontSize:8,color:C.muted,align:'center',margin:0,fit:'shrink'}); });
  notes(s,'Talk about engineering tradeoffs: runtime, weight, durability, and local fallback behavior.');
}

// 13 Security & responsible design
{
  const s = pptx.addSlide(); addDarkBg(s); addTitle(s, 'Security and responsible design', 'Assistive technology must be useful without becoming invasive.', true);
  card(s,0.85,1.4,2.7,1.45,'Privacy','Image processing is designed to run locally when possible; cloud vision is a selected/fallback path, not the only path.',C.violet);
  card(s,3.95,1.4,2.7,1.45,'Safety','The cane’s local obstacle feedback does not depend on internet access, cloud services, or a perfect AI caption.',C.green);
  card(s,7.05,1.4,2.7,1.45,'Transparency','The app should speak concise spatial context and avoid overclaiming uncertain detections.',C.cyan);
  card(s,10.15,1.4,2.35,1.45,'Security','BLE command scope is narrow: navigation commands, telemetry, capture/status, and documented packet formats.',C.amber);
  s.addText('Ethical design stance', { x: 1.2, y: 4.35, w: 3.0, h: 0.32, fontSize: 18, bold: true, color: C.white, margin: 0 });
  s.addText('Prioritize user autonomy, preserve safety-critical functions offline, and make AI assistance explainable enough to trust but bounded enough not to mislead.', { x: 1.25, y: 4.85, w: 10.7, h: 0.58, fontSize: 17, color: 'E2E8F0', margin: 0, fit: 'shrink', align: 'center' });
  addSectionFooter(s,true); notes(s,'This slide supports both final presentation expectations and later ethics/report work.');
}

// 14 Related work
{
  const s = pptx.addSlide('footer'); addTitle(s, 'Related work and differentiation', 'iCAN is positioned between simple smart canes and phone-only navigation aids.');
  const rows = [
    ['Traditional white cane', 'Reliable, low-cost, passive', 'Limited range; poor head-height detection', 'iCAN extends sensing while preserving cane use'],
    ['WeWalk / smart canes', 'Commercial precedent for connected cane systems', 'High cost; limited customization', 'Course prototype explores open, modular architecture'],
    ['Phone-only vision apps', 'Powerful AI descriptions', 'No immediate tactile obstacle feedback', 'iCAN separates local safety from rich scene context'],
    ['Wearable navigation systems', 'Hands-free perception', 'Can be bulky or opaque', 'iCAN uses cane + necklace + phone split']
  ];
  s.addShape(pptx.ShapeType.roundRect,{x:0.75,y:1.35,w:11.85,h:4.55,rectRadius:0.08,fill:{color:'FFFFFF'},line:{color:'E4E7EC'}});
  ['System','Strength','Gap','iCAN response'].forEach((h,i)=>s.addText(h,{x:[1.0,3.55,6.05,8.65][i],y:1.65,w:[2.0,2.0,2.0,3.2][i],h:0.22,fontSize:10,bold:true,color:C.ink,margin:0}));
  rows.forEach((r,ri)=>{
    const y=2.18+ri*0.82;
    s.addShape(pptx.ShapeType.line,{x:0.95,y:y-0.18,w:11.25,h:0,line:{color:'E4E7EC',width:0.5}});
    r.forEach((txt,i)=>s.addText(txt,{x:[1.0,3.55,6.05,8.65][i],y,w:[2.05,2.05,2.05,3.35][i],h:0.45,fontSize:8.3,color:i===0?C.ink:C.slate,bold:i===0,margin:0,fit:'shrink'}));
  });
  notes(s,'Keep this concise. It satisfies related work/comparison without spending too much presentation time.');
}

// 15 Results
{
  const s = pptx.addSlide('footer'); addTitle(s, 'Implementation progress and validation evidence', 'The project has working software structure and documented firmware verification paths.');
  card(s,0.8,1.35,3.05,1.4,'Mobile app','Flutter app includes BLE service, accessible screens, scene-description service, TTS, device pairing, settings, and diagnostic screens.',C.green);
  card(s,4.15,1.35,3.05,1.4,'iCAN Eye','Firmware was refactored into camera, BLE, and main orchestration modules with build environments for main, camera, and BLE stream testing.',C.violet);
  card(s,7.5,1.35,3.05,1.4,'Cane firmware','ProtoSmartCane v2.0 documentation covers battery monitoring, sleep modes, haptic driver, fall alert handling, and deployment checks.',C.blue);
  card(s,10.85,1.35,1.65,1.4,'Repo','Codebase and docs are centralized in GitHub for review.',C.cyan);
  s.addText('Verification currently documented', { x: 1.05, y: 3.6, w: 3.8, h: 0.28, fontSize: 17, bold: true, color: C.ink, margin: 0 });
  const checks=['PlatformIO build environments for iCAN Eye modules','Shared BLE protocol mirrored across firmware/app','App architecture briefing with dependencies and file structure','Deployment checklist for hardware field tests'];
  checks.forEach((t,i)=>{ s.addShape(pptx.ShapeType.ellipse,{x:1.15,y:4.12+i*0.42,w:0.18,h:0.18,fill:{color:C.green},line:{color:C.green}}); s.addText(t,{x:1.45,y:4.06+i*0.42,w:8.9,h:0.2,fontSize:10.5,color:C.slate,margin:0,fit:'shrink'}); });
  s.addText('Project repo: https://github.com/saberrg/ican', { x: 1.15, y: 6.1, w: 4.8, h: 0.22, fontSize: 9.5, color: C.blue, margin: 0 });
  notes(s,'Be careful not to overclaim live field-test results. Present this as implementation and validation evidence.');
}

// 16 Demo plan
{
  const s = pptx.addSlide(); addDarkBg(s); addTitle(s, 'Recorded demo plan', 'Use the 5+ minute demo block to prove the system, not just describe it.', true);
  const demos=[['1','Cane sensing','Show obstacle approach and haptic direction/intensity response.'],['2','BLE telemetry','Show app connection/status and battery/IMU/alert fields.'],['3','Eye capture','Trigger capture and show image/description flow.'],['4','Accessibility UX','Demonstrate spoken output, large controls, and blind-user-oriented flow.']];
  demos.forEach(([n,t,b],i)=>{const x=0.9+i*3.05; s.addShape(pptx.ShapeType.roundRect,{x,y:2.0,w:2.55,h:2.0,rectRadius:0.08,fill:{color:'111827'},line:{color:[C.blue,C.green,C.violet,C.amber][i],width:1.4}}); s.addText(n,{x:x+0.18,y:2.18,w:0.42,h:0.32,fontSize:20,bold:true,color:[C.blue,C.green,C.violet,C.amber][i],margin:0}); s.addText(t,{x:x+0.28,y:2.85,w:2.0,h:0.25,fontSize:15,bold:true,color:C.white,margin:0,fit:'shrink'}); s.addText(b,{x:x+0.28,y:3.28,w:2.0,h:0.52,fontSize:9.5,color:'CBD5E1',margin:0,fit:'shrink'});});
  s.addText('Suggested timing: ~8–9 minutes slides + ~5–6 minutes demo = under 15 minutes total.',{x:1.2,y:5.45,w:10.9,h:0.3,fontSize:14,bold:true,color:C.cyan2,align:'center',margin:0,fit:'shrink'});
  addSectionFooter(s,true); notes(s,'This is tactical: it tells the team exactly what to record for the required video.');
}

// 17 Roadmap
{
  const s = pptx.addSlide('footer'); addTitle(s, 'Remaining work and future improvements', 'The final system has a clear path from prototype to deployable assistive device.');
  card(s,0.8,1.35,2.75,1.35,'Hardware field trial','Validate sensor placement, vibration interpretation, battery estimates, and comfort in walking tests.',C.blue);
  card(s,3.85,1.35,2.75,1.35,'Guided navigation','Integrate Mapbox/walking directions and tune haptic turn timing around obstacle override rules.',C.green);
  card(s,6.9,1.35,2.75,1.35,'Vision optimization','Benchmark local VLM quality/latency and improve spatial descriptions with depth + object fusion.',C.violet);
  card(s,9.95,1.35,2.55,1.35,'Safety review','Improve privacy controls, BLE pairing rules, and failure-mode documentation.',C.amber);
  s.addText('Prototype → verified demo → user-centered field testing → refinement → deployable design', { x: 1.05, y: 4.5, w: 11.0, h: 0.35, fontSize: 18, bold: true, color: C.ink, align: 'center', margin: 0, fit: 'shrink' });
  s.addShape(pptx.ShapeType.line,{x:1.35,y:5.32,w:10.6,h:0,line:{color:C.blue,width:2,endArrowType:'triangle'}});
  ['Prototype','Demo','Field test','Refine','Deploy'].forEach((t,i)=>{const x=1.25+i*2.55; s.addShape(pptx.ShapeType.ellipse,{x,y:5.05,w:0.55,h:0.55,fill:{color:i<2?C.green:C.white},line:{color:C.blue,width:1.2}}); s.addText(t,{x:x-0.35,y:5.72,w:1.25,h:0.2,fontSize:8.5,bold:true,color:C.slate,align:'center',margin:0,fit:'shrink'});});
  notes(s,'Future work should sound credible and prioritized, not like feature creep.');
}

// 18 Contributions
{
  const s = pptx.addSlide('footer'); addTitle(s, 'Team member work contributions', 'Final report and presentation must clearly describe each member’s tasks.');
  card(s,0.85,1.35,2.75,1.55,'Ariel Nyamien','Power and hardware design: sensor/actuator selection, packaging constraints, electrical integration support.',C.blue);
  card(s,3.85,1.35,2.75,1.55,'Aiden Verdin','Controls and embedded systems: firmware logic, sensor processing, state behavior, hardware testing support.',C.green);
  card(s,6.85,1.35,2.75,1.55,'Alex Stokrp','Hardware and circuit design: schematic/BOM support, packaging, sensor placement, physical integration.',C.amber);
  card(s,9.85,1.35,2.75,1.55,'Saber Garibi','Software/app architecture: Flutter app, BLE protocol integration, AI vision pipeline, repo documentation.',C.violet);
  s.addShape(pptx.ShapeType.roundRect,{x:1.0,y:4.75,w:11.2,h:0.72,rectRadius:0.08,fill:{color:'F0F9FF'},line:{color:'B9E6FE'}});
  s.addText('Note: confirm/edit contribution wording before final submission so it matches the team’s actual work split.',{x:1.25,y:4.98,w:10.65,h:0.2,fontSize:11,bold:true,color:'026AA2',align:'center',margin:0,fit:'shrink'});
  notes(s,'This slide is intentionally editable. Saber/team should confirm exact contribution wording before submission.');
}

// 19 Conclusion
{
  const s = pptx.addSlide(); addDarkBg(s); addTitle(s, 'Conclusion', 'iCAN extends mobility feedback without taking control away from the user.', true);
  s.addText('A practical assistive navigation system should be immediate, understandable, and resilient.', { x: 1.0, y: 1.6, w: 11.2, h: 0.55, fontSize: 28, bold: true, color: C.white, align: 'center', margin: 0, fit: 'shrink' });
  card(s,1.15,3.05,3.05,1.35,'Immediate','Obstacle feedback is local and tactile, so basic safety does not depend on cloud AI.',C.green);
  card(s,5.15,3.05,3.05,1.35,'Understandable','Haptics encode side/distance; speech describes spatial context in plain language.',C.cyan);
  card(s,9.15,3.05,3.05,1.35,'Resilient','The cane, eye, and app are modular, documented, and independently testable.',C.violet);
  s.addText('iCAN is a connected ecosystem: embedded sensing for safety, mobile compute for intelligence, and accessible feedback for the user.', { x: 1.25, y: 5.65, w: 10.8, h: 0.38, fontSize: 16, color: 'E2E8F0', align: 'center', margin: 0, fit: 'shrink' });
  addSectionFooter(s,true); notes(s,'End with the core claim: local safety + mobile intelligence + accessibility-first feedback.');
}

// 20 References
{
  const s = pptx.addSlide('footer'); addTitle(s, 'References and source material', 'Key sources used for the final deck.');
  const refs=[
    'Bourne et al., “Global prevalence of blindness and vision impairment,” The Lancet Global Health, 2017. https://doi.org/10.1016/S2214-109X(17)30293-0',
    'iCAN GitHub repository and project documentation: https://github.com/saberrg/ican',
    'Nano ESP32 / XIAO ESP32-S3 / sensor datasheets listed in prior project references and BOM.',
    'Apple Core ML and Vision documentation for on-device perception pipeline.',
    'Moondream project reference for VLM experimentation: https://github.com/vikhyat/moondream',
    'ECE 441 final project requirements and evaluation material from Canvas.'
  ];
  refs.forEach((r,i)=>{s.addShape(pptx.ShapeType.roundRect,{x:0.9,y:1.35+i*0.72,w:11.55,h:0.48,rectRadius:0.04,fill:{color:i%2?'FFFFFF':'F8FAFC'},line:{color:'E4E7EC',transparency:25}}); s.addText(r,{x:1.12,y:1.49+i*0.72,w:11.1,h:0.17,fontSize:8.6,color:C.slate,margin:0,fit:'shrink'});});
  notes(s,'References slide can be expanded if required by the team report/paper, but keep it concise for the presentation.');
}

await pptx.writeFile({ fileName: out });
console.log(out);

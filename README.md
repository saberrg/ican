# iCan App

This application is to be used for Android and iOS smart phones.

This app is a creation from a college course project on embedded systems. The iCan device is a project submission for the ECE 441 course at the Illinois Institute of Technology.

The purpose of this app is for it to be used to enhance the capabilities of the iCan device.

The purpose of the iCan device is to be a modified walking cane for the visually impaired. To learn more about the iCan itself, please visit ./iCan.md

## Visual Description and App Flow (WIP)

#### General Design Principle(s)
The users of this app are visually impaired so the focus should be on reading aloud and having the app recognize the user's voice commands.

### App Startup
The app starts up by announcing itself as "iCan App" and then asks the user what option they would like to do.

Currently, there is 1 option:
1) Say Location
    - The user says "closest McDonald's" or a direct address
    - The app will confirm the location back to the user
    - Then after the user confirmation, the app starts the navigation and configures the haptic motors to guide the user as well.

### The First Page
This page is essentially the app startup, where there is a voice command process as described above. For the user to get their locations. More app features (like pulse, fall detection) will be added later on.

### Features
1. **Pulse and Fall Detection** (Tentative):
   - The pulse sensor will track the heart rate of the user.
   - The fall detection will leverage the IMU to detect sudden changes in orientation, inferring a fall or a dropped cane.

2. **Navigation and Haptic Feedback**:
   - The app integrates both obstacle detection and navigation guidance simultaneously. The system prioritizes feedback based on the urgency of the obstacle versus the navigation instructions.

3. **Bluetooth Communication**:
   - The app communicates with the Arduino Nano for haptic feedback logic and receives image data from the iCan Eye to process and describe the captured images.

4. **Voice Command Recognition**:
   - Voice commands are recognized using platform-specific libraries like Google's Speech-to-Text for Android or Apple's Speech framework for iOS.

5. **Object Detection**:
   - Object detection is performed using TensorFlow Lite or OpenCV on the user's smartphone for more powerful processing.

6. **GPS Navigation**:
   - The app uses the Mapbox SDK for navigation purposes.

## Technical Details
- The app uses Bluetooth Low Energy (BLE) for communication with the iCan device.
- Image processing is offloaded to the user's smartphone to leverage more powerful computing resources.
- The app is designed to be intuitive and user-friendly for visually impaired users.

## Testing and Validation
- Plan for both lab testing and real-world testing with visually impaired users to gather feedback and make necessary adjustments.

## Directory Structure
This project is structured as a monorepo, containing both the mobile app and documentation for the iCan device. Here is a guide to the key directories and files:

- `lib/`: Contains the main Dart/Flutter source code for the mobile application. This is where most of the app logic resides.
- `android/` & `ios/`: Platform-specific build files and configurations for the app.
- `test/`: Contains testing suites to ensure the app functions correctly.
- `assets/`: (To be added) Will contain images, sounds, or other static resources used by the app.
- `firmware/` or `cpp/`: (To be added) Will contain the C++/Arduino source code for the iCan device hardware.
- `iCan.md`: In-depth documentation detailing the hardware specifications and purpose of the physical iCan device.
- `development_plan.md`: Tracks the phases of development, milestones, and upcoming tasks.
- `pubspec.yaml` / `pubspec.lock`: Flutter project metadata and dependencies.

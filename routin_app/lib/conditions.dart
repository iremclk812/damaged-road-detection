import 'package:flutter/material.dart';

class ConditionsPage extends StatefulWidget {
  const ConditionsPage({super.key});

  @override
  State<ConditionsPage> createState() => _ConditionsPageState();
}

class _ConditionsPageState extends State<ConditionsPage> {
  bool isChecked = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.cyanAccent,
        title: const Text("Terms & Conditions"),
      ),
      backgroundColor: const Color.fromARGB(255, 230, 200, 226),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: const Text('''PLEASE READ CAREFULLY...
               before using the [App Name] mobile application (the "Service"). Your access to and use of the Service is conditioned on your acceptance of and compliance with these Terms. 1. Safety and Driver Responsibility (CRITICAL) Safe Operation: The Service is intended to be used as a driver-assistance tool only. You must not interact with the device while driving. All calibrations and "Start/Stop" commands must be performed while the vehicle is stationary and safely parked. Mounting: The device must be securely mounted in a cradle that does not obstruct the driver’s view of the road or interfere with the vehicle's operating controls (e.g., airbags). Legal Compliance: You agree to comply with all local traffic laws and regulations regarding the use of mobile devices in vehicles. The developers are not responsible for any traffic violations or fines. 2. Disclaimer of Liability "As-Is" Basis: The Service is provided on an "AS IS" and "AS AVAILABLE" basis. We do not guarantee that the application will detect every road defect (potholes, cracks, etc.) or that the coordinates provided will be 100% accurate. No Professional Advice: The data collected is for informational purposes only. Do not rely solely on this app for vehicle safety or navigation. Damages: In no event shall the developers or owners be liable for any direct, indirect, incidental, or consequential damages (including, but not limited to, vehicle damage, personal injury, or data loss) arising out of the use or inability to use the Service. 3. Data Collection and Privacy Camera and GPS Access: The Service requires real-time access to your camera and GPS location to function. Data Processing: By using the Service, you acknowledge that the app may capture images of the road, which may incidentally include license plates or pedestrians. Edge Processing: To protect privacy, we strive to process visual data locally on your device ("at the edge"). Recorded clips are stored only when a road defect is detected. Third-Party Sharing: Anonymous telemetry and road defect coordinates may be shared with municipal authorities or road maintenance services to improve infrastructure. 4. Calibration and Engineering Accuracy Accuracy: You acknowledge that the accuracy of road defect detection and distance estimation depends heavily on correct calibration, device mounting, lighting conditions, and vehicle speed. Battery and Storage: The Service uses significant processing power and GPS data. You are responsible for ensuring your device is connected to a power source and has sufficient storage for recorded segments. 5. Intellectual Property All algorithms, UI designs, and detection logic are the intellectual property of [Your Name/Company Name]. You may not reverse-engineer, decompile, or attempt to extract the source code of the application. 6. Termination We reserve the right to terminate or suspend access to our Service immediately, without prior notice or liability, for any reason whatsoever, including without limitation if you breach the Terms.


''', style: TextStyle(fontSize: 14)),
            ),
          ),

          CheckboxListTile(
            title: const Text("Accept Terms and Conditions"),
            value: isChecked,
            onChanged: (value) {
              setState(() {
                isChecked = value ?? false;
              });
            },
          ),

          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: ElevatedButton(
              onPressed: isChecked
                  ? () {
                      Navigator.pop(context, true); // geri dön + true gönder
                    }
                  : null,
              child: const Text("Continue"),
            ),
          ),
        ],
      ),
    );
  }
}

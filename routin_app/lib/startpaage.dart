import 'package:flutter/material.dart';

class Startpaage extends StatefulWidget {
  const Startpaage({super.key});

  @override
  State<Startpaage> createState() => _StartpaageState();
}

class _StartpaageState extends State<Startpaage> {
  bool isChecked = false;
  bool isChecked2 = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          "RoadGuard",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5),
        ),
        centerTitle: true,
      ),
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.add_road_rounded,
                  color: Colors.orangeAccent,
                  size: 80,
                ),
                const SizedBox(height: 16),
                const Text(
                  "Welcome to RoadGuard",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "AI-Powered Road Damage Detection",
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 40),
                TextField(
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.orangeAccent, width: 2),
                    ),
                    labelText: 'Username',
                    labelStyle: const TextStyle(color: Colors.grey),
                    prefixIcon: const Icon(Icons.person, color: Colors.orangeAccent),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.orangeAccent, width: 2),
                    ),
                    labelText: 'Password',
                    labelStyle: const TextStyle(color: Colors.grey),
                    prefixIcon: const Icon(Icons.lock, color: Colors.orangeAccent),
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      debugPrint("Login pressed");
                    },
                    child: const Text(
                      "Login",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Theme(
                  data: Theme.of(context).copyWith(
                    unselectedWidgetColor: Colors.grey,
                  ),
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: Colors.orangeAccent,
                    checkColor: Colors.black87,
                    title: GestureDetector(
                      onTap: () async {
                        final result = await Navigator.pushNamed(
                          context,
                          '/conditions',
                        );

                        if (result == true) {
                          setState(() {
                            isChecked2 = true;
                          });
                        }
                      },
                      child: const Text(
                        "Accept Conditions and Terms",
                        style: TextStyle(
                          decoration: TextDecoration.underline,
                          color: Colors.orangeAccent,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    value: isChecked2,
                    onChanged: (bool? value) {
                      setState(() {
                        isChecked2 = value ?? false;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isChecked2 ? const Color(0xFF4CAF50) : const Color(0xFF2A2A2A),
                      foregroundColor: Colors.white,
                      elevation: isChecked2 ? 4 : 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: isChecked2
                        ? () {
                            Navigator.pushNamed(context, '/splash_screen');
                          }
                        : null,
                    icon: const Icon(Icons.directions_car),
                    label: const Text(
                      "Start Trip",
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

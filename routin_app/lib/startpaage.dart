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
        backgroundColor: Colors.cyanAccent,
        title: Text("Routing App"),
      ),
      backgroundColor: Color.fromARGB(255, 230, 200, 226),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.route, color: Colors.red, size: 50),
              OutlinedButton(
                onPressed: () {
                  debugPrint("Outlined Button pressed");
                },
                child: Text("Outlined Button"),
              ),
              TextField(
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Enter your username',
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              TextField(
                obscureText: true,
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Enter your password',
                  prefixIcon: Icon(Icons.lock),
                ),
              ),
              TextField(
                autocorrect: true,
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Enter your email',
                  prefixIcon: Icon(Icons.email),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  debugPrint("Button pressed");
                },
                onLongPress: () {
                  debugPrint("Button long pressed");
                },
                child: Text("Login "),
              ),
              SizedBox(height: 20),
              CheckboxListTile(
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
                      color: Colors.blue,
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
              ElevatedButton(
                onPressed: isChecked2
                    ? () {
                        Navigator.pushNamed(context, '/splash_screen');
                      }
                    : null,
                child: const Text("Start Trip"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

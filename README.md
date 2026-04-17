🚧 RoadGuard – AI-Based Damaged Road Detection System
📌 Overview

RoadGuard is an intelligent system that detects road defects such as potholes and bumps using computer vision and sensor data integration.
The system processes real-time camera input, estimates the distance to detected defects, and calculates their real-world location.

This project aims to improve road safety and support smart city infrastructure by providing accurate and automated road condition monitoring.

🚀 Features
🧠 AI-Based Detection
Detects road damages using deep learning models on camera input.
📍 Real-Time Location Tracking
Uses GPS data to estimate the real-world coordinates of detected defects.
📏 Distance Estimation
Calculates how far the defect is from the vehicle using camera-based estimation.
📡 Sensor Integration
Detects physical bumps using device sensors (accelerometer).
🗺️ Geolocation & Speed Tracking
Tracks current position and speed for better accuracy.
🗂️ Detection History System
Stores detected defects in a database for later analysis.
🎨 Enhanced UI (OpenCam)
Improved interface for better visibility and usability.
🧠 How It Works
📷 Camera captures road images in real-time
🤖 AI model detects potholes or damages
📐 Distance is calculated using bounding box position
📍 GPS data is used to estimate real-world location
📊 Data is stored in the database
📱 UI displays detection results
🛠️ Technologies Used
Python
OpenCV
ONNX (Model Inference)
Machine Learning / Deep Learning
Geolocation APIs
Sensor Data (Accelerometer)
SQLite / Database Integration
Flutter / Mobile UI (if used)
FastAPI / Flask (

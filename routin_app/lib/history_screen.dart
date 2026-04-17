import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _detections = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final dbPath = await getDatabasesPath();
      final path = p.join(dbPath, 'roadguard_database.db');

      final db = await openDatabase(path);

      // Kaydedilen tespitleri id'ye göre azalan (en yeni en üstte) şekilde getir.
      final result = await db.query('session_detections', orderBy: 'id DESC');

      setState(() {
        _detections = result;
      });

      await db.close();
    } catch (e) {
      debugPrint("Error loading history: $e");
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _clearHistory() async {
    try {
      final dbPath = await getDatabasesPath();
      final path = p.join(dbPath, 'roadguard_database.db');

      final db = await openDatabase(path);
      await db.delete('session_detections');
      await db.delete('session_vibrations'); // İsterseniz bunu da temizleyin
      await db.close();

      _loadHistory(); // Listeyi yenile (boş olacak)

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('History cleared successfully!')),
        );
      }
    } catch (e) {
      debugPrint("Error clearing history: $e");
    }
  }

  void _showClearConfirmDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Clear History', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to delete all detection history? This cannot be undone.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.orangeAccent)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _clearHistory();
            },
            child: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  String _formatDate(String isoString) {
    try {
      final dt = DateTime.parse(isoString).toLocal();
      return "${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } catch (e) {
      return isoString;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detection History', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1E1E1E),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_detections.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
              onPressed: _showClearConfirmDialog,
              tooltip: 'Clear History',
            ),
        ],
      ),
      backgroundColor: const Color(0xFF121212),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orangeAccent))
          : _detections.isEmpty
              ? const Center(
                  child: Text(
                    "No damage records found.",
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _detections.length,
                  itemBuilder: (context, index) {
                    final item = _detections[index];
                    final defectType = item['defectType'] as String? ?? 'Unknown';
                    final conf = (item['confidence'] as num? ?? 0.0) * 100;
                    final lat = item['latitude'] as num? ?? 0.0;
                    final lng = item['longitude'] as num? ?? 0.0;
                    final time = item['timestamp'] as String? ?? '';
                    final isSensor = (item['isSensorConfirmed'] as int? ?? 0) == 1;

                    return Card(
                      color: const Color(0xFF2A2A2A),
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: CircleAvatar(
                          backgroundColor: isSensor ? Colors.redAccent.withValues(alpha: 0.2) : Colors.orangeAccent.withValues(alpha: 0.2),
                          radius: 25,
                          child: Icon(
                            isSensor ? Icons.warning_amber_rounded : Icons.camera_alt,
                            color: isSensor ? Colors.redAccent : Colors.orangeAccent,
                          ),
                        ),
                        title: Text(
                          "$defectType (${conf.toStringAsFixed(1)}%)",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            Text("📍 Lat: ${lat.toStringAsFixed(5)}, Lng: ${lng.toStringAsFixed(5)}",
                                style: const TextStyle(color: Colors.grey, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text("🕒 ${_formatDate(time)}",
                                style: const TextStyle(color: Colors.grey, fontSize: 13)),
                            if (isSensor)
                              Container(
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  "Sensor Confirmed",
                                  style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              )
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}


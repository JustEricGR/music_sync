import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_jobs.dart';
import 'library_sync.dart';
import 'main.dart' show GoogleAuthManager, PersistentBottomMiniPlayer;

// ==========================================
// SYNC BIBLIOTECĂ CU YOUTUBE
// ==========================================
class LibrarySyncScreen extends StatefulWidget {
  const LibrarySyncScreen({super.key});

  @override
  State<LibrarySyncScreen> createState() => _LibrarySyncScreenState();
}

class _LibrarySyncScreenState extends State<LibrarySyncScreen> {
  // Sync-ul rulează în SyncJob (global): continuă și dacă ieși din ecran
  // sau din aplicație; ecranul doar îl afișează.
  final SyncJob _job = SyncJob.instance;
  final ScrollController _logScrollController = ScrollController();
  String? _rootPath;

  List<String> get _logs => _job.logs;
  bool get _isRunning => _job.isRunning;
  LibrarySyncReport? get _report => _job.lastReport;

  @override
  void initState() {
    super.initState();
    _job.addListener(_onJobChanged);
    _loadRoot();
  }

  @override
  void dispose() {
    _job.removeListener(_onJobChanged);
    _logScrollController.dispose();
    super.dispose();
  }

  void _onJobChanged() {
    if (!mounted) return;
    setState(() {});
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _loadRoot() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _rootPath = prefs.getString('saved_output_dir'));
  }

  Future<void> _startSync({bool dryRun = false}) async {
    final root = _rootPath;
    if (root == null || !Directory(root).existsSync()) {
      _job.addLog('[EROARE] Nu există un folder de bibliotecă. Alege-l din Bibliotecă sau Downloader.');
      return;
    }

    _job.addLog('Conectare la contul Google...');
    try {
      final creds = await GoogleAuthManager.instance.signIn();
      if (creds == null) {
        _job.addLog('[EROARE] Conectarea Google a fost anulată.');
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final customIds = (prefs.getStringList('custom_playlists') ?? []).toSet();

      await _job.run(
        api: GoogleAuthManager.youtubeApiFor(creds),
        root: Directory(root),
        customPlaylistIds: customIds,
        dryRun: dryRun,
      );
    } catch (e) {
      _job.addLog('[EXCEPȚIE] $e');
    }
  }

  Widget _summaryCard(LibrarySyncReport report) {
    Widget section(String title, List<String> items, IconData icon, Color color) {
      if (items.isEmpty) return const SizedBox.shrink();
      return ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text('$title (${items.length})'),
        children: items.map((i) => ListTile(dense: true, title: Text(i))).toList(),
      );
    }

    final nothingChanged = report.renamed.isEmpty &&
        report.removedSongs.isEmpty &&
        report.removedPlaylists.isEmpty &&
        report.reordered.isEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(nothingChanged ? Icons.check_circle : Icons.sync_alt, color: Colors.green),
            title: Text('${report.checkedPlaylists} playlisturi verificate'),
            subtitle: Text(nothingChanged ? 'Totul era la zi.' : 'Biblioteca a fost actualizată.'),
          ),
          section('Redenumite', report.renamed, Icons.drive_file_rename_outline, Colors.blueAccent),
          section('Playlisturi șterse de pe YouTube', report.removedPlaylists, Icons.playlist_remove, Colors.redAccent),
          section('Melodii mutate în "Removed Songs"', report.removedSongs, Icons.remove_circle_outline, Colors.orangeAccent),
          section('Ordine refăcută ca pe YouTube', report.reordered, Icons.format_list_numbered, Colors.lightBlueAccent),
          section('Păstrate (indisponibile pe YouTube)', report.keptUnavailable, Icons.shield_outlined, Colors.tealAccent),
          section('Nelegate de YouTube (neschimbate)', report.unmatched, Icons.link_off, Colors.grey),
          section('Erori', report.errors, Icons.error_outline, Colors.redAccent),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync Bibliotecă')),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Pentru fiecare playlist descărcat:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text('• dacă și-a schimbat numele pe YouTube, folderul și playlistul din player primesc noul nume;'),
                  const Text('• melodiile scoase din playlist pe YouTube sunt mutate în "Removed Songs" și dispar din player.'),
                  const Text('• playlisturile care nu mai există pe YouTube sunt mutate în "Removed Songs/Playlisturi șterse";'),
                  const Text('• melodiile sunt puse exact în ordinea din playlistul YouTube.'),
                  const SizedBox(height: 8),
                  Text(
                    _rootPath != null ? 'Bibliotecă: $_rootPath' : 'Niciun folder de bibliotecă ales.',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _isRunning
                        ? OutlinedButton.icon(
                            icon: const Icon(Icons.stop),
                            label: const Text('Oprește'),
                            onPressed: _job.cancel,
                          )
                        // Unul sub altul: alăturate, textele se rupeau pe telefon ("Previzualiz-are").
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ElevatedButton.icon(
                                icon: const Icon(Icons.sync),
                                label: const Text('Pornește sync-ul'),
                                onPressed: _rootPath == null ? null : _startSync,
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.preview),
                                label: const Text('Previzualizare'),
                                onPressed: _rootPath == null ? null : () => _startSync(dryRun: true),
                              ),
                            ],
                          ),
                  ),
                  if (_isRunning) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
          if (report != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
              child: SingleChildScrollView(child: _summaryCard(report)),
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.all(8),
              padding: const EdgeInsets.all(8),
              color: Colors.black87,
              child: ListView.builder(
                controller: _logScrollController,
                itemCount: _logs.length,
                itemBuilder: (context, idx) => Text(
                  _logs[idx],
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
          const PersistentBottomMiniPlayer(),
        ],
      ),
    );
  }
}

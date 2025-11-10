import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DictionaryApp());
}

class DictionaryApp extends StatelessWidget {
  const DictionaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Dictionary',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const DictionaryHomePage(),
    );
  }
}

class DictionaryHomePage extends StatefulWidget {
  const DictionaryHomePage({super.key});

  @override
  State<DictionaryHomePage> createState() => _DictionaryHomePageState();
}

class _DictionaryHomePageState extends State<DictionaryHomePage> {
  final TextEditingController _controller = TextEditingController();
  final ApiService _api = ApiService();
  final FavoritesStore _favoritesStore = FavoritesStore();

  StreamSubscription<ConnectivityResult>? _connSub;
  bool _isOnline = true;

  bool _loading = false;
  String? _error;
  List<WordEntry> _results = [];

  // Audio player (single shared instance)
  final AudioPlayer _player = AudioPlayer();
  String? _currentUrl;
  PlayerState _playerState = PlayerState.stopped;

  // Favorites in-memory cache
  final Map<String, WordEntry> _favoritesByWord = {};

  @override
  void initState() {
    super.initState();
    // Connectivity
    Connectivity().checkConnectivity().then(_updateConnectivity);
    _connSub = Connectivity().onConnectivityChanged.listen(_updateConnectivity);

    // Load favorites
    _loadFavorites();

    // Listen for player state updates
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _playerState = state;
        });
      }
    });
  }

  Future<void> _loadFavorites() async {
    final favs = await _favoritesStore.load();
    if (!mounted) return;
    setState(() {
      _favoritesByWord
        ..clear()
        ..addEntries(favs.map((e) => MapEntry(e.word.toLowerCase(), e)));
    });
  }

  void _updateConnectivity(ConnectivityResult result) {
    final online = result != ConnectivityResult.none;
    if (mounted) {
      setState(() {
        _isOnline = online;
      });
    }
  }

  Future<void> _search(String raw) async {
    final word = raw.trim();
    if (word.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });

    try {
      final entries = await _api.lookup(word);
      setState(() {
        _results = entries;
      });
    } on SocketException {
      setState(() {
        _error = 'No Internet connection. Please check your network.';
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
      });
    } catch (_) {
      setState(() {
        _error = 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _toggleFavorite(WordEntry entry) async {
    final key = entry.word.toLowerCase();
    final exists = _favoritesByWord.containsKey(key);
    if (exists) {
      _favoritesByWord.remove(key);
    } else {
      _favoritesByWord[key] = entry;
    }
    await _favoritesStore.save(_favoritesByWord.values.toList());
    if (mounted) setState(() {});
  }

  bool _isFavorite(String word) => _favoritesByWord.containsKey(word.toLowerCase());

  Future<void> _playAudio(String? rawUrl) async {
    final url = normalizeAudioUrl(rawUrl);
    if (url == null) return;

    try {
      if (_currentUrl == url && _playerState == PlayerState.playing) {
        await _player.pause();
        return;
      }
      _currentUrl = url;
      await _player.stop();
      await _player.setSourceUrl(url);
      await _player.resume();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to play audio')),
      );
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _controller.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = !_isOnline
        ? const _NoInternet()
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _search,
                        decoration: InputDecoration(
                          hintText: 'Enter an English word (e.g., hello)',
                          prefixIcon: const Icon(Icons.search),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => _search(_controller.text),
                      icon: const Icon(Icons.search),
                      label: const Text('Search'),
                    ),
                  ],
                ),
              ),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(child: _buildContent()),
            ],
          );

    final isPlaying = _playerState == PlayerState.playing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Dictionary'),
        actions: [
          if (!_isOnline)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.wifi_off, color: Colors.redAccent),
            ),
          IconButton(
            tooltip: 'Favorites',
            icon: const Icon(Icons.favorite),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => FavoritesPage(
                    favorites: _favoritesByWord.values.toList(),
                    onRemove: (entry) async {
                      final key = entry.word.toLowerCase();
                      _favoritesByWord.remove(key);
                      await _favoritesStore.save(_favoritesByWord.values.toList());
                      if (mounted) setState(() {});
                    },
                    onPlay: _playAudio,
                  ),
                ),
              );
              // On return, refresh from storage (in case of external updates)
              await _loadFavorites();
            },
          ),
          if (_currentUrl != null)
            IconButton(
              tooltip: isPlaying ? 'Pause audio' : 'Play audio',
              icon: Icon(isPlaying ? Icons.pause_circle : Icons.play_circle),
              onPressed: () => _playAudio(_currentUrl),
            ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return _ErrorState(message: _error!);
    }
    if (_results.isEmpty) {
      return const _EmptyState();
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final entry = _results[index];
        final playableUrl = firstPlayableAudio(entry);
        final isFav = _isFavorite(entry.word);
        return _WordEntryCard(
          entry: entry,
          isFavorite: isFav,
          onToggleFavorite: () => _toggleFavorite(entry),
          onPlay: playableUrl != null ? () => _playAudio(playableUrl) : null,
          isCurrentlyPlaying: _currentUrl != null &&
              playableUrl != null &&
              _currentUrl == normalizeAudioUrl(playableUrl) &&
              _playerState == PlayerState.playing,
        );
      },
    );
  }
}

class _NoInternet extends StatelessWidget {
  const _NoInternet();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.wifi_off, size: 72, color: Colors.redAccent),
            SizedBox(height: 16),
            Text(
              'No Internet connection',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Please check your network and try again.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.menu_book, size: 72, color: Colors.indigo),
            SizedBox(height: 16),
            Text(
              'Search for any English word',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Powered by dictionaryapi.dev',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.orange),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}

class _WordEntryCard extends StatelessWidget {
  final WordEntry entry;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onPlay;
  final bool isCurrentlyPlaying;

  const _WordEntryCard({
    required this.entry,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.onPlay,
    this.isCurrentlyPlaying = false,
  });

  @override
  Widget build(BuildContext context) {
    final playableUrl = firstPlayableAudio(entry);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: word + actions
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    entry.word,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: isFavorite ? 'Remove from favorites' : 'Add to favorites',
                  icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border,
                      color: isFavorite ? Colors.redAccent : null),
                  onPressed: onToggleFavorite,
                ),
                if (playableUrl != null)
                  IconButton(
                    tooltip: isCurrentlyPlaying ? 'Pause pronunciation' : 'Play pronunciation',
                    icon: Icon(isCurrentlyPlaying ? Icons.pause_circle : Icons.volume_up),
                    onPressed: onPlay,
                  ),
              ],
            ),
            if (entry.phonetic != null && entry.phonetic!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  entry.phonetic!,
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (entry.origin != null && entry.origin!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  'Origin: ${entry.origin!}',
                  style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic),
                ),
              ),
            const SizedBox(height: 12),
            ...entry.meanings.map((m) => _MeaningTile(meaning: m)).toList(),
          ],
        ),
      ),
    );
  }
}

class _MeaningTile extends StatelessWidget {
  final Meaning meaning;
  const _MeaningTile({required this.meaning});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            meaning.partOfSpeech,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          ...meaning.definitions.asMap().entries.map((e) {
            final idx = e.key + 1;
            final d = e.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$idx. ${d.definition}'),
                  if (d.example != null && d.example!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2.0),
                      child: Text(
                        'Example: ${d.example!}',
                        style: const TextStyle(
                          fontStyle: FontStyle.italic,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
          if (meaning.synonyms.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                const Text('Synonyms:', style: TextStyle(fontWeight: FontWeight.w500)),
                ...meaning.synonyms.take(8).map((s) => Chip(label: Text(s))).toList(),
              ],
            ),
          if (meaning.antonyms.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6.0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  const Text('Antonyms:', style: TextStyle(fontWeight: FontWeight.w500)),
                  ...meaning.antonyms.take(8).map((s) => Chip(label: Text(s))).toList(),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/* ===========================
   Favorites Page
   =========================== */

class FavoritesPage extends StatelessWidget {
  final List<WordEntry> favorites;
  final Future<void> Function(WordEntry) onRemove;
  final Future<void> Function(String?) onPlay;

  const FavoritesPage({
    super.key,
    required this.favorites,
    required this.onRemove,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = [...favorites]..sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));
    return Scaffold(
      appBar: AppBar(title: const Text('Favorites')),
      body: sorted.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Text('No favorites yet. Add from search results.'),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: sorted.length,
              itemBuilder: (context, index) {
                final entry = sorted[index];
                final playable = firstPlayableAudio(entry);
                return Dismissible(
                  key: ValueKey(entry.word.toLowerCase()),
                  background: Container(
                    color: Colors.red.shade100,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: const Icon(Icons.delete, color: Colors.red),
                  ),
                  secondaryBackground: Container(
                    color: Colors.red.shade100,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: const Icon(Icons.delete, color: Colors.red),
                  ),
                  onDismissed: (_) => onRemove(entry),
                  child: Card(
                    elevation: 0,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    child: ListTile(
                      title: Text(entry.word, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: entry.phonetic != null && entry.phonetic!.isNotEmpty
                          ? Text(entry.phonetic!)
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (playable != null)
                            IconButton(
                              tooltip: 'Play pronunciation',
                              icon: const Icon(Icons.volume_up),
                              onPressed: () => onPlay(playable),
                            ),
                          IconButton(
                            tooltip: 'Remove from favorites',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => onRemove(entry),
                          ),
                        ],
                      ),
                      onTap: () {
                        // Expand to see details
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: Text(entry.word)),
                            body: ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                _WordEntryCard(
                                  entry: entry,
                                  isFavorite: true,
                                  onToggleFavorite: () => onRemove(entry),
                                  onPlay: playable != null ? () => onPlay(playable) : null,
                                ),
                              ],
                            ),
                          ),
                        ));
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/* ===========================
   API + Models + Storage
   =========================== */

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class ApiService {
  static const _base = 'https://api.dictionaryapi.dev/api/v2/entries/en';

  Future<List<WordEntry>> lookup(String word) async {
    final uri = Uri.parse('$_base/$word');
    http.Response res;
    try {
      res = await http.get(uri).timeout(const Duration(seconds: 15));
    } on SocketException {
      throw SocketException('No Internet');
    } on TimeoutException {
      throw ApiException('Request timed out. Please try again.');
    }

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      if (data is List) {
        return data.map<WordEntry>((e) => WordEntry.fromJson(e as Map<String, dynamic>)).toList();
      } else {
        throw ApiException('Unexpected response format.');
      }
    }

    try {
      final err = jsonDecode(res.body);
      if (err is Map<String, dynamic>) {
        final title = err['title'] ?? 'Not found';
        final message = err['message'] ?? 'No definitions found.';
        final resolution = err['resolution'] ?? '';
        throw ApiException('$title: $message ${resolution.toString()}'.trim());
      }
    } catch (_) {}
    throw ApiException('Error ${res.statusCode}: Unable to fetch definition.');
  }
}

class FavoritesStore {
  static const _prefsKey = 'favorites_v1';

  Future<List<WordEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_prefsKey) ?? const [];
    final list = <WordEntry>[];
    for (final jsonStr in rawList) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        list.add(WordEntry.fromJson(map));
      } catch (_) {
        // ignore corrupt entry
      }
    }
    return list;
  }

  Future<void> save(List<WordEntry> favorites) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = favorites.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList(_prefsKey, encoded);
  }
}

class WordEntry {
  final String word;
  final String? phonetic;
  final List<Phonetic> phonetics;
  final String? origin;
  final List<Meaning> meanings;

  WordEntry({
    required this.word,
    required this.phonetics,
    required this.meanings,
    this.phonetic,
    this.origin,
  });

  factory WordEntry.fromJson(Map<String, dynamic> json) {
    final phoneticsJson = (json['phonetics'] as List?) ?? const [];
    return WordEntry(
      word: (json['word'] ?? '').toString(),
      phonetic: (json['phonetic'] as String?)?.trim(),
      phonetics: phoneticsJson
          .whereType<Map<String, dynamic>>()
          .map((p) => Phonetic.fromJson(p))
          .toList(),
      origin: (json['origin'] as String?)?.trim(),
      meanings: ((json['meanings'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((m) => Meaning.fromJson(m))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'word': word,
        'phonetic': phonetic,
        'phonetics': phonetics.map((e) => e.toJson()).toList(),
        'origin': origin,
        'meanings': meanings.map((e) => e.toJson()).toList(),
      };
}

class Phonetic {
  final String? text;
  final String? audio;
  Phonetic({this.text, this.audio});
  factory Phonetic.fromJson(Map<String, dynamic> json) {
    return Phonetic(
      text: (json['text'] as String?)?.trim(),
      audio: (json['audio'] as String?)?.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        'text': text,
        'audio': audio,
      };
}

class Meaning {
  final String partOfSpeech;
  final List<Definition> definitions;
  final List<String> synonyms;
  final List<String> antonyms;

  Meaning({
    required this.partOfSpeech,
    required this.definitions,
    required this.synonyms,
    required this.antonyms,
  });

  factory Meaning.fromJson(Map<String, dynamic> json) {
    return Meaning(
      partOfSpeech: (json['partOfSpeech'] ?? '').toString(),
      definitions: ((json['definitions'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((d) => Definition.fromJson(d))
          .toList(),
      synonyms: ((json['synonyms'] as List?) ?? const []).map((e) => e.toString()).toList(),
      antonyms: ((json['antonyms'] as List?) ?? const []).map((e) => e.toString()).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'partOfSpeech': partOfSpeech,
        'definitions': definitions.map((e) => e.toJson()).toList(),
        'synonyms': synonyms,
        'antonyms': antonyms,
      };
}

class Definition {
  final String definition;
  final String? example;
  final List<String> synonyms;
  final List<String> antonyms;

  Definition({
    required this.definition,
    this.example,
    required this.synonyms,
    required this.antonyms,
  });

  factory Definition.fromJson(Map<String, dynamic> json) {
    return Definition(
      definition: (json['definition'] ?? '').toString(),
      example: (json['example'] as String?)?.trim(),
      synonyms: ((json['synonyms'] as List?) ?? const []).map((e) => e.toString()).toList(),
      antonyms: ((json['antonyms'] as List?) ?? const []).map((e) => e.toString()).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'definition': definition,
        'example': example,
        'synonyms': synonyms,
        'antonyms': antonyms,
      };
}

/* ===========================
   Audio helpers
   =========================== */

String? firstPlayableAudio(WordEntry entry) {
  for (final p in entry.phonetics) {
    final u = normalizeAudioUrl(p.audio);
    if (u != null) return u;
  }
  return null;
}

String? normalizeAudioUrl(String? url) {
  if (url == null) return null;
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('//')) return 'https:$trimmed';
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) return trimmed;
  // Some sources might be relative; ignore them
  return null;
}
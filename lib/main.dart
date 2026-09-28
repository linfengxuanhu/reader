import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

void main() {
  runApp(const DailyReaderApp());
}

class DailyReaderApp extends StatelessWidget {
  const DailyReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Daily Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.brown,
      ),
      home: const HomePage(),
    );
  }
}

class Book {
  final String title;
  final List<Chapter> chapters;
  Book({required this.title, required this.chapters});
}

class Chapter {
  final String title;
  final String content;
  Chapter({required this.title, required this.content});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loading = false;
  String _status = '';

  final Color backgroundColor = const Color(0xFFFFFDF5);
  final Color textColor = const Color(0xFF333333);

  Future<void> openEpub() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
      withData: false,
    );

    if (result == null || result.files.single.path == null) return;

    final file = result.files.single;

    setState(() {
      _loading = true;
      _status = '正在解析…';
    });

    Book? book;
    String errMsg = '';
    try {
      final bytes = await File(file.path!).readAsBytes();
      book = await _parseEpub(bytes, file.name);
    } catch (e, st) {
      debugPrint('❌ 解析异常: $e\n$st');
      errMsg = e.toString();
      book = null;
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
      _status = '';
    });

    if (book == null || book.chapters.isEmpty) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('打开失败'),
          content: Text(
            '没有找到正文内容。\n\n'
            '可能原因：\n'
            '• 这本书是加密的（DRM）\n'
            '• EPUB 结构异常\n'
            '• 文件损坏\n\n'
            '${errMsg.isNotEmpty ? '错误信息：$errMsg' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          book: book!,
          backgroundColor: backgroundColor,
          textColor: textColor,
        ),
      ),
    );
  }

  // ================================================================
  //  核心解析逻辑
  // ================================================================
  Future<Book> _parseEpub(Uint8List data, String fallbackTitle) async {
    final archive = ZipDecoder().decodeBytes(data);

    // 1. 把所有文件收集起来，建立小写路径 -> 文件 的索引
    final Map<String, ArchiveFile> map = {};
    final List<String> allPaths = [];
    for (final f in archive) {
      if (!f.isFile) continue;
      final key = _norm(f.name);
      map[key] = f;
      allPaths.add(key);
    }

    debugPrint('📦 共 ${allPaths.length} 个文件');
    debugPrint('📦 文件列表: $allPaths');

    // 2. 找 OPF（走标准流程）；失败就 fallback
    String? opfKey = _findOpfKey(map, allPaths);
    debugPrint('📖 opfKey = $opfKey');

    List<String> orderedFiles = [];
    String title = fallbackTitle;

    if (opfKey != null) {
      try {
        final opfXml = _decodeBytes(_bytes(map[opfKey]!));
        final doc = XmlDocument.parse(opfXml);

        // 书名
        final t = doc.findAllElements('dc:title').firstOrNull ??
            doc.findAllElements('title').firstOrNull;
        if (t != null && t.text.trim().isNotEmpty) {
          title = t.text.trim();
        }

        // manifest: id -> href
        final manifest = <String, String>{};
        for (final e in doc.findAllElements('item')) {
          final id = e.getAttribute('id');
          final href = e.getAttribute('href');
          final mt = e.getAttribute('media-type') ?? '';
          if (id != null && href != null) {
            if (mt.contains('html') ||
                href.toLowerCase().endsWith('.xhtml') ||
                href.toLowerCase().endsWith('.html') ||
                href.toLowerCase().endsWith('.htm')) {
              manifest[id] = href;
            }
          }
        }

        // spine 顺序
        final opfDir = p.dirname(opfKey);
        for (final e in doc.findAllElements('itemref')) {
          final idref = e.getAttribute('idref');
          if (idref == null) continue;
          final href = manifest[idref];
          if (href == null) continue;
          final clean = href.split('#').first;
          final full = _norm(p.join(opfDir, clean));
          if (map.containsKey(full)) {
            orderedFiles.add(full);
          }
        }

        debugPrint('📖 spine 顺序文件数: ${orderedFiles.length}');
      } catch (e) {
        debugPrint('⚠️ OPF 解析失败，走 fallback: $e');
        opfKey = null;
      }
    }

    // 3. 如果 spine 拿到的为空，就把所有 html 文件按路径排序当章节
    if (orderedFiles.isEmpty) {
      orderedFiles = allPaths
          .where((k) =>
              k.endsWith('.xhtml') ||
              k.endsWith('.html') ||
              k.endsWith('.htm'))
          .toList()
        ..sort();
      debugPrint('📖 fallback 顺序文件数: ${orderedFiles.length}');
    }

    // 4. 逐个解析成纯文本
    final chapters = <Chapter>[];
    for (final key in orderedFiles) {
      final f = map[key];
      if (f == null) continue;
      final text = _htmlToText(_bytes(f));
      if (text.trim().isEmpty) continue;
      chapters.add(Chapter(
        title: _guessTitle(text, chapters.length + 1),
        content: text,
      ));
    }

    debugPrint('✅ 章节数: ${chapters.length}');
    return Book(title: title, chapters: chapters);
  }

  // 在压缩包里找 opf
  String? _findOpfKey(Map<String, ArchiveFile> map, List<String> allPaths) {
    // 优先从 container.xml 拿
    final c = map['meta-inf/container.xml'];
    if (c != null) {
      try {
        final doc = XmlDocument.parse(_decodeBytes(_bytes(c)));
        final rf = doc.findAllElements('rootfile').firstOrNull;
        final full = rf?.getAttribute('full-path');
        if (full != null && full.isNotEmpty) {
          final key = _norm(full);
          if (map.containsKey(key)) return key;
        }
      } catch (_) {}
    }
    // 退而求其次：扫全包里第一个 .opf
    for (final k in allPaths) {
      if (k.endsWith('.opf')) return k;
    }
    return null;
  }

  // ================================================================
  //  工具
  // ================================================================
  Uint8List _bytes(ArchiveFile f) =>
      Uint8List.fromList(f.content as List<int>);

  String _decodeBytes(Uint8List bytes) {
    // 先试 UTF-8，失败试 GBK 系（中文电子书常见）
    try {
      return utf8.decode(bytes);
    } catch (_) {}
    try {
      // latin1 兜底，虽然会乱码但不至于抛异常
      return latin1.decode(bytes);
    } catch (_) {
      return '';
    }
  }

  String _norm(String path) => path.replaceAll('\\', '/').toLowerCase();

  /// HTML -> 纯文本（保留段落换行）
  String _htmlToText(Uint8List bytes) {
    final html = _decodeBytes(bytes);
    if (html.isEmpty) return '';

    final doc = html_parser.parse(html);
    final body = doc.body ?? doc.documentElement;
    if (body == null) return '';

    final buf = StringBuffer();

    void walk(dom.Node node) {
      if (node is dom.Text) {
        buf.write(node.text);
        return;
      }
      if (node is! dom.Element) return;

      final tag = node.localName?.toLowerCase() ?? '';
      const blockTags = {
        'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
        'li', 'blockquote', 'section', 'article', 'tr', 'br',
      };
      final isBlock = blockTags.contains(tag);

      if (isBlock && buf.isNotEmpty && !buf.toString().endsWith('\n')) {
        buf.write('\n');
      }
      if (tag == 'br') {
        buf.write('\n');
        return;
      }
      for (final c in node.nodes) {
        walk(c);
      }
      if (isBlock && !buf.toString().endsWith('\n')) {
        buf.write('\n');
      }
    }

    for (final c in body.nodes) {
      walk(c);
    }

    return buf
        .toString()
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  String _guessTitle(String text, int index) {
    final first = text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (first.isEmpty) return '第 $index 章';
    return first.length > 30 ? '${first.substring(0, 30)}…' : first;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Daily Reader')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.menu_book_rounded, size: 80),
              const SizedBox(height: 24),
              const Text(
                'EPUB 阅读器',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text('选择一本 EPUB 开始阅读'),
              const SizedBox(height: 32),
              if (_loading) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(_status),
              ] else
                FilledButton.icon(
                  onPressed: openEpub,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('打开 EPUB'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class ReaderPage extends StatefulWidget {
  final Book book;
  final Color backgroundColor;
  final Color textColor;

  const ReaderPage({
    super.key,
    required this.book,
    required this.backgroundColor,
    required this.textColor,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late int chapter;
  double fontSize = 20;
  final ScrollController _ctrl = ScrollController();

  String get _progressKey => 'chapter_${widget.book.title}';

  @override
  void initState() {
    super.initState();
    chapter = 0;
    _loadProgress();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_progressKey);
    if (saved != null && mounted) {
      setState(() {
        chapter = saved.clamp(0, widget.book.chapters.length - 1);
      });
    }
  }

  Future<void> _saveProgress() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_progressKey, chapter);
  }

  void _goTo(int index) {
    if (index < 0 || index >= widget.book.chapters.length) return;
    setState(() => chapter = index);
    _saveProgress();
    if (_ctrl.hasClients) _ctrl.jumpTo(0);
  }

  void _showChapterList() {
    showModalBottomSheet(
      context: context,
      builder: (_) => ListView.builder(
        itemCount: widget.book.chapters.length,
        itemBuilder: (_, i) {
          final c = widget.book.chapters[i];
          return ListTile(
            selected: i == chapter,
            title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              Navigator.pop(context);
              _goTo(i);
            },
          );
        },
      ),
    );
  }

  void _showFontSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('字体大小',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Slider(
                min: 14,
                max: 32,
                value: fontSize,
                onChanged: (v) {
                  setState(() => fontSize = v);
                  setSheet(() {});
                },
              ),
              Text('${fontSize.toInt()} px'),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.book.chapters.length;
    final current = widget.book.chapters[chapter];

    return Scaffold(
      backgroundColor: widget.backgroundColor,
      appBar: AppBar(
        backgroundColor: widget.backgroundColor,
        title: Text(widget.book.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              icon: const Icon(Icons.list),
              tooltip: '章节列表',
              onPressed: _showChapterList),
          IconButton(
              icon: const Icon(Icons.text_fields), onPressed: _showFontSheet),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _ctrl,
              padding: const EdgeInsets.fromLTRB(24, 30, 24, 80),
              children: [
                SelectableText(
                  current.content,
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: fontSize,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: widget.backgroundColor,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: chapter > 0 ? () => _goTo(chapter - 1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${chapter + 1} / $total'),
                  IconButton(
                    onPressed:
                        chapter < total - 1 ? () => _goTo(chapter + 1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

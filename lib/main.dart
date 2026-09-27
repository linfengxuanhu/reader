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

/// 一本书解析后的结构
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

  final Color backgroundColor = const Color(0xFFFFFDF5);
  final Color textColor = const Color(0xFF333333);

  Future<void> openEpub() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
      withData: false, // 流式读取，避免大书 OOM
    );

    if (result == null || result.files.single.path == null) return;

    final file = result.files.single;

    setState(() => _loading = true);

    Book? book;
    try {
      final bytes = await File(file.path!).readAsBytes();
      book = await _parseEpub(bytes, file.name);
    } catch (e) {
      book = null;
      debugPrint('EPUB 解析失败: $e');
    }

    if (!mounted) return;
    setState(() => _loading = false);

    if (book == null || book.chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有找到 EPUB 正文内容')),
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

  /// 解析 EPUB：
  /// 1. 读 META-INF/container.xml 找 .opf
  /// 2. 读 .opf 的 manifest + spine，得到正确章节顺序
  /// 3. 按顺序解析每个 XHTML 为纯文本（保留段落换行）
  Future<Book> _parseEpub(Uint8List data, String fallbackTitle) async {
    final archive = ZipDecoder().decodeBytes(data);

    final Map<String, ArchiveFile> fileMap = {};
    for (final f in archive) {
      if (f.isFile) {
        fileMap[_normalize(f.name)] = f;
      }
    }

    // ---------- 1. container.xml ----------
    String opfPath = '';
    final container = fileMap['meta-inf/container.xml'];
    if (container != null) {
      final xmlStr = _decodeBytes(_fileBytes(container));
      try {
        final doc = XmlDocument.parse(xmlStr);
        final rootfile = doc.findAllElements('rootfile').firstOrNull;
        opfPath = rootfile?.getAttribute('full-path') ?? '';
      } catch (_) {}
    }

    if (opfPath.isEmpty) {
      return _fallbackParse(fileMap, fallbackTitle);
    }

    final opfKey = _normalize(opfPath);
    final opfFile = fileMap[opfKey];
    if (opfFile == null) {
      return _fallbackParse(fileMap, fallbackTitle);
    }

    final opfXml = _decodeBytes(_fileBytes(opfFile));
    final XmlDocument opfDoc;
    try {
      opfDoc = XmlDocument.parse(opfXml);
    } catch (_) {
      return _fallbackParse(fileMap, fallbackTitle);
    }

    final opfDir = p.dirname(opfKey);

    // ---------- 2. manifest + spine ----------
    final manifest = <String, String>{};
    for (final item in opfDoc.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        manifest[id] = href;
      }
    }

    final spineIds = <String>[];
    for (final itemref in opfDoc.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      if (idref != null) spineIds.add(idref);
    }

    String title = fallbackTitle;
    final titleEl = opfDoc.findAllElements('dc:title').firstOrNull ??
        opfDoc.findAllElements('title').firstOrNull;
    if (titleEl != null && titleEl.text.trim().isNotEmpty) {
      title = titleEl.text.trim();
    }

    // ---------- 3. 按 spine 顺序解析 ----------
    final chapters = <Chapter>[];

    for (final id in spineIds) {
      final href = manifest[id];
      if (href == null) continue;

      final cleanHref = href.split('#').first;
      final fullPath = _normalize(p.join(opfDir, cleanHref));

      final entry = fileMap[fullPath];
      if (entry == null) continue;

      final text = _htmlToPlainText(_fileBytes(entry));
      if (text.trim().isEmpty) continue;

      final chapterTitle =
          _extractTitle(text) ?? '第 ${chapters.length + 1} 章';

      chapters.add(Chapter(title: chapterTitle, content: text));
    }

    return Book(title: title, chapters: chapters);
  }

  /// 找不到 opf 时退化处理
  Book _fallbackParse(Map<String, ArchiveFile> fileMap, String title) {
    final chapters = <Chapter>[];
    final keys = fileMap.keys.toList()..sort();

    for (final key in keys) {
      if (key.endsWith('.xhtml') ||
          key.endsWith('.html') ||
          key.endsWith('.htm')) {
        final text = _htmlToPlainText(_fileBytes(fileMap[key]!));
        if (text.trim().isEmpty) continue;

        chapters.add(Chapter(
          title: _extractTitle(text) ?? '第 ${chapters.length + 1} 章',
          content: text,
        ));
      }
    }
    return Book(title: title, chapters: chapters);
  }

  // ---------- 工具 ----------

  Uint8List _fileBytes(ArchiveFile f) =>
      Uint8List.fromList(f.content as List<int>);

  String _decodeBytes(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  String _normalize(String path) =>
      path.replaceAll('\\', '/').toLowerCase();

  /// HTML -> 纯文本，保留段落换行
  String _htmlToPlainText(Uint8List bytes) {
    final html = _decodeBytes(bytes);
    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return '';

    final buffer = StringBuffer();

    void walk(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.text);
      } else if (node is dom.Element) {
        final tag = node.localName;
        final isBlock = const {
          'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
          'li', 'blockquote', 'section', 'article', 'tr',
        }.contains(tag);

        if (isBlock && buffer.isNotEmpty && !buffer.toString().endsWith('\n\n')) {
          buffer.write('\n\n');
        }

        if (tag == 'br') {
          buffer.write('\n');
        } else {
          for (final child in node.nodes) {
            walk(child);
          }
        }

        if (isBlock && !buffer.toString().endsWith('\n\n')) {
          buffer.write('\n\n');
        }
      }
    }

    for (final child in body.nodes) {
      walk(child);
    }

    return buffer
        .toString()
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  String? _extractTitle(String text) {
    final firstLine = text.split('\n').firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
    if (firstLine.isEmpty) return null;
    return firstLine.length > 30
        ? '${firstLine.substring(0, 30)}…'
        : firstLine;
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
              if (_loading)
                const CircularProgressIndicator()
              else
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
  final ScrollController _scrollCtrl = ScrollController();

  String get _progressKey => 'chapter_${widget.book.title}';

  @override
  void initState() {
    super.initState();
    chapter = 0;
    _loadProgress();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
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

  void _goToChapter(int index) {
    if (index < 0 || index >= widget.book.chapters.length) return;
    setState(() => chapter = index);
    _saveProgress();
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(0);
    }
  }

  void _showChapterList() {
    showModalBottomSheet(
      context: context,
      builder: (_) {
        return ListView.builder(
          itemCount: widget.book.chapters.length,
          itemBuilder: (_, i) {
            final c = widget.book.chapters[i];
            return ListTile(
              selected: i == chapter,
              title: Text(
                c.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(context);
                _goToChapter(i);
              },
            );
          },
        );
      },
    );
  }

  void _showFontSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '字体大小',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Slider(
                    min: 14,
                    max: 32,
                    value: fontSize,
                    onChanged: (value) {
                      setState(() => fontSize = value);
                      setSheetState(() {});
                    },
                  ),
                  Text('${fontSize.toInt()} px'),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.book.chapters.length;
    final current = widget.book.chapters[chapter];

    return Scaffold(
      backgroundColor: widget.backgroundColor,
      appBar: AppBar(
        title: Text(
          widget.book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: widget.backgroundColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            tooltip: '章节列表',
            onPressed: _showChapterList,
          ),
          IconButton(
            icon: const Icon(Icons.text_fields),
            onPressed: _showFontSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scrollCtrl,
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: widget.backgroundColor,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: chapter > 0
                        ? () => _goToChapter(chapter - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${chapter + 1} / $total'),
                  IconButton(
                    onPressed: chapter < total - 1
                        ? () => _goToChapter(chapter + 1)
                        : null,
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

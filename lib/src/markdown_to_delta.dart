import 'dart:collection';
import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/models/rules/format.dart';
import 'package:markdown/markdown.dart' as md;

/// Converts markdown [md.Element] to [Attribute].
typedef ElementToAttributeConvertor = Attribute Function(
  Map<String, String> elAttrs,
);

/// Converts markdown [md.Element] to [Embeddable].
typedef ElementToEmbeddableConvertor = Embeddable Function(
  Map<String, String> elAttrs,
);

/// Convertor from Markdown string to quill [Delta].
class MarkdownToDelta extends Converter<String, Delta>
    implements md.NodeVisitor {
  ///
  MarkdownToDelta({
    required this.markdownDocument,
    this.customElementToInlineAttribute = const {},
    this.customElementToBlockAttribute = const {},
    this.customElementToEmbeddable = const {},
    this.softLineBreak = false,
  });

  final md.Document markdownDocument;
  final Map<String, ElementToAttributeConvertor> customElementToInlineAttribute;
  final Map<String, ElementToAttributeConvertor> customElementToBlockAttribute;
  final Map<String, ElementToEmbeddableConvertor> customElementToEmbeddable;
  final bool softLineBreak;

  // final _blockTags = <String>[
  //   'p',
  //   'h1',
  //   'h2',
  //   'h3',
  //   'h4',
  //   'h5',
  //   'h6',
  //   'li',
  //   'blockquote',
  //   'pre',
  //   'ol',
  //   'ul',
  //   'hr',
  //   'table',
  //   'thead',
  //   'tbody',
  //   'tr'
  // ];

  final _elementToBlockAttr = <String, ElementToAttributeConvertor>{
    'ul': (_) => Attribute.ul,
    'ol': (_) => Attribute.ol,
    'pre': (_) => Attribute.codeBlock,
    'blockquote': (_) => Attribute.blockQuote,
    'h1': (_) => Attribute.h1,
    'h2': (_) => Attribute.h2,
    'h3': (_) => Attribute.h3,
  };

  final _elementToInlineAttr = <String, ElementToAttributeConvertor>{
    'em': (_) => Attribute.italic,
    'strong': (_) => Attribute.bold,
    'del': (_) => Attribute.strikeThrough,
    'a': (elAttrs) => LinkAttribute(elAttrs['href']),
    'code': (_) => Attribute.inlineCode,
  };

  final _elementToEmbed = <String, ElementToEmbeddableConvertor>{
    'hr': (_) => BlockEmbed.horizontalRule,
    'img': (elAttrs) => BlockEmbed.image(elAttrs['src'] ?? ''),
  };

  var _delta = Delta();
  final _activeInlineAttributes = Queue<Attribute>();
  final _activeBlockAttributes = Queue<Attribute>();
  final _topLevelNodes = <md.Node>[];
  bool _isInBlockquote = false;
  bool _isInCodeblock = false;
  bool _justPreviousBlockExit = false;
  String? _lastTag;
  String? _currentBlockTag;
  int _listItemIndent = -1;

  @override
  Delta convert(String input) {
    _delta = Delta();
    _activeInlineAttributes.clear();
    _activeBlockAttributes.clear();
    _topLevelNodes.clear();
    _lastTag = null;
    _currentBlockTag = null;
    _isInBlockquote = false;
    _isInCodeblock = false;
    _justPreviousBlockExit = false;
    _listItemIndent = -1;

    final lines = const LineSplitter().convert(input);
    final mdNodes = markdownDocument.parseLines(lines);

    _topLevelNodes.addAll(mdNodes);

    for (final node in mdNodes) {
      node.accept(this);
    }

    // Ensure the delta ends with a newline.
    _appendLastNewLineIfNeeded();

    return _delta;
  }

  void _appendLastNewLineIfNeeded() {
    if (_delta.isEmpty) return;
    final dynamic lastValue = _delta.last.value;
    if (!(lastValue is String && lastValue.endsWith('\n'))) {
      _delta.insert('\n', _effectiveBlockAttrs());
    }
  }

  @override
  void visitText(md.Text text) {
    String renderedText;
    if (_isInBlockquote) {
      renderedText = text.text;
    } else if (_isInCodeblock) {
      renderedText = text.text.endsWith('\n')
          ? text.text.substring(0, text.text.length - 1)
          : text.text;
    } else {
      renderedText = _trimTextToMdSpec(text.text);
    }

    if (renderedText.contains('\n')) {
      var lines = renderedText.split('\n');
      if (renderedText.endsWith('\n')) {
        lines = lines.sublist(0, lines.length - 1);
      }
      for (var i = 0; i < lines.length; i++) {
        final isLastItem = i == lines.length - 1;
        final line = lines[i];
        _delta.insert(line, _effectiveInlineAttrs());
        if (!isLastItem) {
          _delta.insert('\n', _effectiveBlockAttrs());
        }
      }
    } else {
      _delta.insert(renderedText, _effectiveInlineAttrs());
    }
    _lastTag = null;
    _justPreviousBlockExit = false;
  }

  @override
  bool visitElementBefore(md.Element element) {
    _insertNewLineBeforeElementIfNeeded(element);

    final tag = element.tag;
    _currentBlockTag ??= tag;
    _lastTag = tag;

    if (_haveBlockAttrs(element)) {
      _activeBlockAttributes.addLast(_toBlockAttribute(element));
    }
    if (_haveInlineAttrs(element)) {
      _activeInlineAttributes.addLast(_toInlineAttribute(element));
    }

    if (tag == 'blockquote') {
      _isInBlockquote = true;
    }

    if (tag == 'pre') {
      _isInCodeblock = true;
    }

    if (tag == 'li') {
      _listItemIndent++;
    }

    return true;
  }

  @override
  void visitElementAfter(md.Element element) {
    final tag = element.tag;

    if (_isEmbedElement(element)) {
      _delta.insert(_toEmbeddable(element).toJson());
    }

    if (tag == 'br') {
      _delta.insert('\n');
    }

    // exit block with new line
    // hr need to be followed by new line
    _insertNewLineAfterElementIfNeeded(element);

    if (tag == 'blockquote') {
      _isInBlockquote = false;
    }

    if (tag == 'pre') {
      _isInCodeblock = false;
    }

    if (tag == 'li') {
      _listItemIndent--;
    }

    if (_haveBlockAttrs(element)) {
      _activeBlockAttributes.removeLast();
    }

    if (_haveInlineAttrs(element)) {
      _activeInlineAttributes.removeLast();
    }

    if (_currentBlockTag == tag) {
      _currentBlockTag = null;
    }
    _lastTag = tag;
  }

  void _insertNewLine() {
    _delta.insert('\n', _effectiveBlockAttrs());
  }

  void _insertNewLineBeforeElementIfNeeded(md.Element element) {
    if (!_isInBlockquote &&
        _lastTag == 'blockquote' &&
        element.tag == 'blockquote') {
      _insertNewLine();
      return;
    }

    if (!_isInCodeblock && _lastTag == 'pre' && element.tag == 'pre') {
      _insertNewLine();
      return;
    }

    if (_listItemIndent >= 0 && (element.tag == 'ul' || element.tag == 'ol')) {
      _insertNewLine();
      return;
    }
  }

  void _insertNewLineAfterElementIfNeeded(md.Element element) {
    if (element.tag == 'hr') {
      // Always add new line after divider
      _justPreviousBlockExit = true;
      _insertNewLine();
      return;
    }

    if (!_justPreviousBlockExit &&
        (_isTopLevelNode(element) ||
            _haveBlockAttrs(element) ||
            element.tag == 'li')) {
      _justPreviousBlockExit = true;
      _insertNewLine();
      return;
    }
  }

  bool _isTopLevelNode(md.Node node) => _topLevelNodes.contains(node);

  Map<String, dynamic>? _effectiveBlockAttrs() {
    if (_activeBlockAttributes.isEmpty) return null;
    final attrsRespectingExclusivity = <Attribute>[
      if (_listItemIndent > 0) IndentAttribute(level: _listItemIndent),
    ];

    for (final attr in _activeBlockAttributes) {
      final isExclusiveAttr = Attribute.exclusiveBlockKeys.contains(
        attr.key,
      );
      final isThereAlreadyExclusiveAttr = attrsRespectingExclusivity.any(
        (element) => Attribute.exclusiveBlockKeys.contains(element.key),
      );

      if (!(isExclusiveAttr && isThereAlreadyExclusiveAttr)) {
        attrsRespectingExclusivity.add(attr);
      }
    }

    return <String, dynamic>{
      for (final a in attrsRespectingExclusivity) ...a.toJson(),
    };
  }

  Map<String, dynamic>? _effectiveInlineAttrs() {
    if (_activeInlineAttributes.isEmpty) return null;
    return <String, dynamic>{
      for (final a in _activeInlineAttributes) ...a.toJson(),
    };
  }

  // Define trim text function to remove spaces from text elements in
  // accordance with Markdown specifications.
  String _trimTextToMdSpec(String text) {
    var result = text;
    // The leading spaces pattern is used to identify spaces
    // at the beginning of a line of text.
    final _leadingSpacesPattern = RegExp('^ *');

    // The soft line break is used to identify the spaces at the end of a line
    // of text and the leading spaces in the immediately following the line
    // of text. These spaces are removed in accordance with the Markdown
    // specification on soft line breaks when lines of text are joined.
    final _softLineBreak = RegExp(r' ?\n *');

    // Leading spaces following a hard line break are ignored.
    // https://github.github.com/gfm/#example-657
    if (const ['p', 'ol', 'li', 'br'].contains(_lastTag)) {
      result = result.replaceAll(_leadingSpacesPattern, '');
    }

    if (softLineBreak) {
      return result;
    }
    return result.replaceAll(_softLineBreak, ' ');
  }

  Map<String, ElementToAttributeConvertor> _effectiveElementToInlineAttr() {
    return {
      ...customElementToInlineAttribute,
      ..._elementToInlineAttr,
    };
  }

  bool _haveInlineAttrs(md.Element element) {
    if (_isInCodeblock && element.tag == 'code') return false;
    return _effectiveElementToInlineAttr().containsKey(element.tag);
  }

  Attribute _toInlineAttribute(md.Element element) {
    Attribute? result;
    if (!(_isInCodeblock && element.tag == 'code')) {
      result = _effectiveElementToInlineAttr()[element.tag]
          ?.call(element.attributes);
    }
    if (result == null) {
      throw Exception(
          'Element $element cannot be converted to inline attribute');
    }
    return result;
  }

  Map<String, ElementToAttributeConvertor> _effectiveElementToBlockAttr() {
    return {
      ...customElementToBlockAttribute,
      ..._elementToBlockAttr,
    };
  }

  bool _haveBlockAttrs(md.Element element) {
    return _effectiveElementToBlockAttr().containsKey(element.tag);
  }

  Attribute _toBlockAttribute(md.Element element) {
    final result =
        _effectiveElementToBlockAttr()[element.tag]?.call(element.attributes);
    if (result == null) {
      throw Exception(
          'Element $element cannot be converted to block attribute');
    }
    return result;
  }

  Map<String, ElementToEmbeddableConvertor> _effectiveElementToEmbed() {
    return {
      ...customElementToEmbeddable,
      ..._elementToEmbed,
    };
  }

  bool _isEmbedElement(md.Element element) =>
      _effectiveElementToEmbed().containsKey(element.tag);

  Embeddable _toEmbeddable(md.Element element) {
    final result =
        _effectiveElementToEmbed()[element.tag]?.call(element.attributes);
    if (result == null) {
      throw Exception('Element $element cannot be converted to Embeddable');
    }
    return result;
  }

// bool _isBlockElement(md.Element element) => _blockTags.contains(element.tag);
}
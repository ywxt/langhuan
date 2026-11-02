/// Best-effort re-indenter for JavaScript feed scripts.
///
/// This is a reading aid for the pre-install audit viewer, not a real code
/// formatter: it splits statements onto their own lines and re-indents by
/// bracket depth while leaving string, template, regex, and comment contents
/// untouched. Spacing inside a line is preserved as written (only collapsed),
/// so the output remains a faithful rearrangement of the input rather than a
/// re-styled rewrite. The audit page always labels the result as a derived
/// view — the script that installs is the untouched original.
String formatJavaScript(String source) {
  final out = _LineWriter();
  var i = 0;

  // Last significant token pieces, for regex-vs-division detection.
  var lastChar = '';
  var lastWord = '';

  // Keywords after which a `/` opens a regex literal, not division.
  const regexKeywords = {
    'return',
    'typeof',
    'instanceof',
    'in',
    'of',
    'case',
    'delete',
    'void',
    'new',
    'do',
    'else',
    'throw',
    'yield',
    'await',
  };

  bool regexAllowed() {
    if (lastChar.isEmpty) return true;
    final identifierLike = RegExp(r'[A-Za-z0-9_$\)\]]').hasMatch(lastChar);
    return !identifierLike || regexKeywords.contains(lastWord);
  }

  void rememberWord(String word) {
    lastChar = word[word.length - 1];
    lastWord = word;
  }

  void rememberChar(String ch) {
    lastChar = ch;
    lastWord = '';
  }

  while (i < source.length) {
    final c = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';

    // ── Comments ───────────────────────────────────────────────────
    if (c == '/' && next == '/') {
      var end = source.indexOf('\n', i);
      if (end < 0) end = source.length;
      out.write(source.substring(i, end).trimRight());
      out.newline();
      i = end < source.length ? end + 1 : end;
      rememberChar('/');
      continue;
    }
    if (c == '/' && next == '*') {
      var end = source.indexOf('*/', i + 2);
      end = end < 0 ? source.length : end + 2;
      out.write(source.substring(i, end));
      out.newline();
      i = end;
      rememberChar('/');
      continue;
    }

    // ── Strings and templates ──────────────────────────────────────
    if (c == '"' || c == "'" || c == '`') {
      var j = i + 1;
      var terminated = false;
      while (j < source.length) {
        final s = source[j];
        if (s == '\\') {
          j += 2;
          continue;
        }
        if (s == c) {
          j++;
          terminated = true;
          break;
        }
        // A raw newline cannot appear inside a normal string literal;
        // bail there so malformed input cannot swallow the rest of the
        // file. Templates may span lines.
        if (s == '\n' && c != '`') break;
        j++;
      }
      if (j > source.length) j = source.length;
      out.write(source.substring(i, j));
      // An unterminated literal means malformed input; stop the line.
      if (!terminated) out.newline();
      i = j;
      rememberChar(c);
      continue;
    }

    // ── Regex literals ─────────────────────────────────────────────
    if (c == '/' && regexAllowed()) {
      var j = i + 1;
      var inClass = false;
      while (j < source.length) {
        final s = source[j];
        if (s == '\\') {
          j += 2;
          continue;
        }
        if (s == '\n') break; // malformed regex; stop here
        if (inClass) {
          if (s == ']') inClass = false;
        } else if (s == '[') {
          inClass = true;
        } else if (s == '/') {
          j++;
          while (j < source.length && RegExp(r'[a-z]').hasMatch(source[j])) {
            j++;
          }
          break;
        }
        j++;
      }
      if (j > source.length) j = source.length;
      out.write(source.substring(i, j));
      i = j;
      rememberChar('/');
      continue;
    }

    // ── Whitespace ─────────────────────────────────────────────────
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      out.space();
      i++;
      continue;
    }

    // ── Structure ──────────────────────────────────────────────────
    switch (c) {
      case '{':
        out.spaceBeforeBrace();
        out.write('{');
        out.depth++;
        out.newline();
        i++;
        rememberChar('{');
        continue;
      case '}':
        if (out.depth > 0) out.depth--;
        out.newline();
        out.write('}');
        // What follows decides whether the line continues: continuation
        // keywords keep a space (`} else {`), closing punctuation stays
        // attached (`});`, `},`, `}.`), and anything else starts a new
        // statement on its own line.
        var j = i + 1;
        while (j < source.length && ' \t\n\r'.contains(source[j])) {
          j++;
        }
        if (j >= source.length) {
          i++;
          rememberChar('}');
          continue;
        }
        final continuation = RegExp(
          r'[A-Za-z_$][A-Za-z0-9_$]*',
        ).matchAsPrefix(source, j);
        if (continuation != null) {
          if (const {
            'else',
            'catch',
            'finally',
            'while',
          }.contains(continuation.group(0))) {
            out.space();
          } else {
            out.newline();
          }
        } else if (!')];,.}('.contains(source[j])) {
          out.newline();
        }
        i++;
        rememberChar('}');
        continue;
      case ';':
        out.write(';');
        if (out.parens == 0) out.newline();
        i++;
        rememberChar(';');
        continue;
      case '(':
        out.parens++;
        out.write('(');
        i++;
        rememberChar('(');
        continue;
      case ')':
        if (out.parens > 0) out.parens--;
        out.write(')');
        i++;
        rememberChar(')');
        continue;
    }

    // ── Words and everything else ──────────────────────────────────
    final word = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*').matchAsPrefix(source, i);
    if (word != null) {
      out.write(word.group(0)!);
      rememberWord(word.group(0)!);
      i = word.end;
      continue;
    }
    final number = RegExp(r'[0-9]+(\.[0-9]+)*').matchAsPrefix(source, i);
    if (number != null) {
      out.write(number.group(0)!);
      rememberWord(number.group(0)!);
      i = number.end;
      continue;
    }
    out.write(c);
    i++;
    rememberChar(c);
  }

  out.newline();
  return out.toString();
}

/// Accumulates output line by line, tracking block depth and pending
/// whitespace so indentation is generated rather than copied.
class _LineWriter {
  static const _indent = '  ';

  final _lines = <String>[];
  final _line = StringBuffer();
  var depth = 0;
  var parens = 0;
  var _pendingSpace = false;
  var _atLineStart = true;
  var _lastWritten = '';

  /// Append text to the current line. A pending space from earlier
  /// whitespace materializes first — unless the line is just starting, where
  /// source whitespace is treated as indentation and replaced.
  void write(String text) {
    if (text.isEmpty) return;
    if (_atLineStart) {
      _atLineStart = false;
      _pendingSpace = false;
      _line.write(_indent * depth);
    } else if (_pendingSpace) {
      _pendingSpace = false;
      _line.write(' ');
    }
    _line.write(text);
    _lastWritten = text[text.length - 1];
  }

  /// Conventional single space before a block-opening brace — unless it
  /// directly follows an opening bracket (`foo({`, `[{`) or nothing, where
  /// one would be wrong.
  void spaceBeforeBrace() {
    if (_atLineStart || _pendingSpace) return;
    if (_lastWritten == '(' || _lastWritten == '[') return;
    _pendingSpace = true;
  }

  /// Mark that whitespace was seen; it collapses to at most one space.
  void space() => _pendingSpace = true;

  /// End the current line. Blank lines are never produced.
  void newline() {
    if (_line.isEmpty) return;
    _lines.add(_line.toString());
    _line.clear();
    _pendingSpace = false;
    _atLineStart = true;
  }

  @override
  String toString() => _lines.join('\n');
}

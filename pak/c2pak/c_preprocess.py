"""Minimal C preprocessor for the c2pak transpiler.

Handles the most common patterns found in N64 homebrew / decomp C files:
  - #define NAME value   → collected into a macro table
  - #define NAME(args)   → tracked as function-like macros
  - #include "file.h"    → optionally resolved for type information
  - #ifdef / #ifndef / #endif  → stripped (we assume a fixed target platform)
  - Line-continuation (backslash-newline) → joined

This is intentionally lightweight. For complex macro-heavy code use
`gcc -E` external preprocessing (see c_parser.py).
"""

from __future__ import annotations
import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, TYPE_CHECKING


# ── GCC extension stripping ───────────────────────────────────────────────────

def strip_gcc_extensions(source: str) -> str:
    """Strip GCC-specific extensions that pycparser cannot handle.

    Removes/replaces:
      - __attribute__((anything))
      - __extension__
      - __restrict, __restrict__
      - __volatile__ → volatile
      - __inline__, __inline → inline
      - __asm__("...") blocks
      - typeof(x) → int (placeholder)
      - __builtin_expect(x, y) → x
      - __builtin_offsetof(T, f) → offsetof(T, f)
      - __builtin_va_list (kept — handled by prelude typedef)
    """
    # __attribute__((...)) — handle nested parens
    source = _strip_attribute(source)

    # __asm__("...") or asm volatile ("...") — remove entire asm block
    source = re.sub(r'\b(?:__asm__|asm)\s*(?:volatile\s*)?\([^;]*\)\s*;?', '', source)
    source = re.sub(r'\b(?:__asm__|asm)\s*(?:volatile\s*)?\([^;]*\)', '', source)

    # __extension__ keyword — just remove it
    source = re.sub(r'\b__extension__\b', '', source)

    # __restrict, __restrict__
    source = re.sub(r'\b__restrict(?:__)?(?=\s)', ' ', source)

    # __volatile__ → volatile
    source = re.sub(r'\b__volatile__\b', 'volatile', source)

    # __inline__, __inline → inline
    source = re.sub(r'\b__inline(?:__)?(?=\s|\()', 'inline', source)

    # __builtin_expect(x, y) → x
    source = _replace_builtin_expect(source)

    # __builtin_offsetof(T, f) → offsetof(T, f)
    source = re.sub(r'\b__builtin_offsetof\b', 'offsetof', source)

    # typeof(x) → int  (placeholder — we can't infer the type)
    source = re.sub(r'\btypeof\s*\([^)]*\)', 'int', source)

    # __typeof__(x) → int
    source = re.sub(r'\b__typeof__\s*\([^)]*\)', 'int', source)

    return source


def _strip_attribute(source: str) -> str:
    """Remove __attribute__((...)) constructs, handling nested parens."""
    result = []
    i = 0
    n = len(source)
    attr_pat = re.compile(r'__attribute__\s*\(')
    while i < n:
        m = attr_pat.search(source, i)
        if m is None:
            result.append(source[i:])
            break
        result.append(source[i:m.start()])
        # Find matching closing paren (need double parens: __attribute__((..)))
        j = m.end()  # position after first '('
        depth = 1
        while j < n and depth > 0:
            if source[j] == '(':
                depth += 1
            elif source[j] == ')':
                depth -= 1
            j += 1
        i = j  # skip past the entire __attribute__((...))
    return ''.join(result)


def _replace_builtin_expect(source: str) -> str:
    """Replace __builtin_expect(x, y) with x."""
    result = []
    i = 0
    n = len(source)
    pat = re.compile(r'__builtin_expect\s*\(')
    while i < n:
        m = pat.search(source, i)
        if m is None:
            result.append(source[i:])
            break
        result.append(source[i:m.start()])
        j = m.end()
        depth = 1
        start_inner = j
        # Find the first argument (up to the first comma at depth 1)
        first_arg_end = None
        while j < n and depth > 0:
            if source[j] == '(':
                depth += 1
            elif source[j] == ')':
                depth -= 1
                if depth == 0:
                    if first_arg_end is None:
                        first_arg_end = j
            elif source[j] == ',' and depth == 1:
                if first_arg_end is None:
                    first_arg_end = j
            j += 1
        if first_arg_end is not None:
            result.append(source[start_inner:first_arg_end])
        i = j
    return ''.join(result)


# ── Macro representation ──────────────────────────────────────────────────────

@dataclass
class SimpleMacro:
    """A #define NAME value constant macro."""
    name: str
    value: str          # raw text of the expansion


@dataclass
class FuncMacro:
    """A #define NAME(params) body function-like macro."""
    name: str
    params: List[str]
    body: str


# ── Preprocessor ──────────────────────────────────────────────────────────────

class Preprocessor:
    """Lightweight C preprocessor that strips directives and collects macros."""

    def __init__(self):
        self.simple_macros: Dict[str, SimpleMacro] = {}
        self.func_macros: Dict[str, FuncMacro] = {}
        # Each entry: (currently_active, any_branch_taken_in_this_chain)
        self._ifdef_stack: List[Tuple[bool, bool]] = []

    # ── Public API ────────────────────────────────────────────────────────────

    def process(self, source: str) -> Tuple[str, Dict[str, SimpleMacro]]:
        """Process *source* text.

        Returns:
            (cleaned_source, simple_macros) where cleaned_source has all
            preprocessor directives removed/resolved and simple_macros is a
            dict of all #define NAME value macros collected.
        """
        source = self._join_line_continuations(source)
        lines = source.splitlines(keepends=True)
        out_lines: List[str] = []
        for line in lines:
            stripped = line.lstrip()
            if stripped.startswith('#'):
                self._handle_directive(stripped)
                # Emit a blank line to preserve line numbers approximately
                out_lines.append('\n')
            else:
                if self._is_active():
                    out_lines.append(line)
                else:
                    out_lines.append('\n')
        cleaned = ''.join(out_lines)
        # Expand function-like macros inline so pycparser sees real C code
        if self.func_macros:
            cleaned = _expand_func_macros(cleaned, self.func_macros)
        return cleaned, dict(self.simple_macros)

    # ── Directive handling ────────────────────────────────────────────────────

    def _handle_directive(self, line: str):
        """Dispatch a # directive line."""
        line = line.rstrip()
        # Remove the leading '#' and optional spaces
        content = line[1:].lstrip()
        if not content:
            return

        # Split keyword from rest
        parts = content.split(None, 1)
        keyword = parts[0]
        rest = parts[1] if len(parts) > 1 else ''

        if keyword == 'define':
            self._handle_define(rest)
        elif keyword in ('ifdef', 'ifndef'):
            name = rest.strip().split()[0] if rest.strip() else ''
            defined = name in self.simple_macros or name in self.func_macros
            condition = defined if keyword == 'ifdef' else not defined
            active = self._is_active() and condition
            # Push (currently_active, any_branch_taken_in_chain)
            self._ifdef_stack.append((active, active))
        elif keyword == 'if':
            # Simplified: treat #if 0 as inactive, everything else active
            val = rest.strip()
            active = self._is_active() and val != '0'
            self._ifdef_stack.append((active, active))
        elif keyword == 'elif':
            if self._ifdef_stack:
                # Pop current frame; check whether any branch was already taken
                _, any_taken = self._ifdef_stack.pop()
                val = rest.strip()
                condition = val != '0'
                # Active only if parent is active, no prior branch taken, and condition holds
                active = self._is_active() and not any_taken and condition
                self._ifdef_stack.append((active, any_taken or active))
        elif keyword == 'else':
            if self._ifdef_stack:
                _, any_taken = self._ifdef_stack.pop()
                # Active only if parent is active and no prior branch was taken
                active = self._is_active() and not any_taken
                self._ifdef_stack.append((active, True))
        elif keyword == 'endif':
            if self._ifdef_stack:
                self._ifdef_stack.pop()
        # #include, #pragma, #error, etc. — ignored

    def _handle_define(self, rest: str):
        """Parse a #define directive body."""
        if not rest:
            return
        # Function-like macro: NAME(params) body
        m = re.match(r'(\w+)\(([^)]*)\)\s*(.*)', rest, re.DOTALL)
        if m:
            name = m.group(1)
            params = [p.strip() for p in m.group(2).split(',') if p.strip()]
            body = m.group(3).strip()
            self.func_macros[name] = FuncMacro(name=name, params=params, body=body)
            return
        # Simple macro: NAME value (or just NAME)
        parts = rest.split(None, 1)
        name = parts[0]
        value = parts[1].strip() if len(parts) > 1 else '1'
        self.simple_macros[name] = SimpleMacro(name=name, value=value)

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _is_active(self) -> bool:
        """Return True if we're in an active (non-skipped) branch."""
        return all(active for active, _ in self._ifdef_stack) if self._ifdef_stack else True

    @staticmethod
    def _join_line_continuations(source: str) -> str:
        """Join lines ending with a backslash."""
        return re.sub(r'\\\n', ' ', source)


def strip_comments(source: str) -> str:
    """Remove C-style /* ... */ and // ... comments from *source*.

    Preserves line count by replacing comment content with spaces/newlines
    so that pycparser line numbers stay approximately correct.
    """
    result = []
    i = 0
    n = len(source)
    while i < n:
        # Block comment
        if source[i] == '/' and i + 1 < n and source[i + 1] == '*':
            i += 2
            while i < n:
                if source[i] == '*' and i + 1 < n and source[i + 1] == '/':
                    i += 2
                    result.append(' ')
                    break
                elif source[i] == '\n':
                    result.append('\n')
                i += 1
        # Line comment
        elif source[i] == '/' and i + 1 < n and source[i + 1] == '/':
            i += 2
            while i < n and source[i] != '\n':
                i += 1
            # Keep the newline
        # String literal — don't strip comments inside strings
        elif source[i] == '"':
            result.append(source[i])
            i += 1
            while i < n:
                if source[i] == '\\' and i + 1 < n:
                    result.append(source[i])
                    result.append(source[i + 1])
                    i += 2
                elif source[i] == '"':
                    result.append(source[i])
                    i += 1
                    break
                else:
                    result.append(source[i])
                    i += 1
        # Char literal
        elif source[i] == "'":
            result.append(source[i])
            i += 1
            while i < n:
                if source[i] == '\\' and i + 1 < n:
                    result.append(source[i])
                    result.append(source[i + 1])
                    i += 2
                elif source[i] == "'":
                    result.append(source[i])
                    i += 1
                    break
                else:
                    result.append(source[i])
                    i += 1
        else:
            result.append(source[i])
            i += 1
    return ''.join(result)


def _extract_macro_args(source: str, start: int) -> Tuple[Optional[List[str]], int]:
    """Extract comma-separated arguments starting at *start* (after the opening '(').

    Returns (args, end_pos) where end_pos is the position after the closing ')'.
    Returns (None, start) on parse failure.
    """
    args: List[str] = []
    current: List[str] = []
    depth = 1
    i = start
    n = len(source)
    while i < n and depth > 0:
        c = source[i]
        if c == '(':
            depth += 1
            current.append(c)
        elif c == ')':
            depth -= 1
            if depth == 0:
                args.append(''.join(current))
                i += 1
                break
            current.append(c)
        elif c == ',' and depth == 1:
            args.append(''.join(current))
            current = []
        else:
            current.append(c)
        i += 1
    else:
        return None, start  # unterminated call
    return args, i


def _expand_one_macro(source: str, name: str, macro: FuncMacro) -> str:
    """Expand all calls to *name* in *source*."""
    pattern = re.compile(r'\b' + re.escape(name) + r'\s*\(')
    result: List[str] = []
    i = 0
    while i < len(source):
        m = pattern.search(source, i)
        if not m:
            result.append(source[i:])
            break
        result.append(source[i:m.start()])
        j = m.end()
        args, end_pos = _extract_macro_args(source, j)
        if args is None:
            result.append(source[m.start():j])
            i = j
            continue
        # Normalise: a 0-param macro invoked as MACRO() gives args=['']
        if len(macro.params) == 0 and args == ['']:
            args = []
        if len(args) != len(macro.params):
            # Wrong arg count — leave unexpanded
            result.append(source[m.start():end_pos])
            i = end_pos
            continue
        # Substitute each param with its argument (wrapped in parens for safety)
        body = macro.body
        for param, arg in zip(macro.params, args):
            body = re.sub(r'\b' + re.escape(param) + r'\b',
                          '(' + arg.strip() + ')', body)
        result.append(body)
        i = end_pos
    return ''.join(result)


def _expand_func_macros(source: str, func_macros: Dict[str, FuncMacro]) -> str:
    """Expand simple function-like macros in *source*.

    Skips macros whose body contains '#' (stringification / token-pasting).
    Repeats expansion up to 10 times to handle macros that call other macros.
    """
    expandable = {
        name: macro
        for name, macro in func_macros.items()
        if '#' not in macro.body
    }
    if not expandable:
        return source
    for _ in range(10):
        new_source = source
        for name, macro in expandable.items():
            new_source = _expand_one_macro(new_source, name, macro)
        if new_source == source:
            break
        source = new_source
    return source


def preprocess(source: str) -> Tuple[str, Dict[str, SimpleMacro]]:
    """Convenience function: preprocess *source* and return cleaned text + macros."""
    # First strip GCC extensions
    source = strip_gcc_extensions(source)
    # Then strip comments (pycparser can't handle them)
    source = strip_comments(source)
    pp = Preprocessor()
    return pp.process(source)


def capture_comments(source: str) -> List[Tuple[int, str]]:
    """Capture C comments and return list of (line_number, text) tuples.

    Captures both block comments /* ... */ and line comments // ...
    Line numbers are 1-based.
    """
    comments = []
    i = 0
    n = len(source)
    line_num = 1

    while i < n:
        # Block comment
        if source[i] == '/' and i + 1 < n and source[i + 1] == '*':
            start_line = line_num
            i += 2
            text_parts = ['/*']
            while i < n:
                if source[i] == '*' and i + 1 < n and source[i + 1] == '/':
                    text_parts.append('*/')
                    i += 2
                    break
                elif source[i] == '\n':
                    line_num += 1
                    text_parts.append('\n')
                else:
                    text_parts.append(source[i])
                i += 1
            text = ''.join(text_parts)
            # Extract just the content
            content = text[2:-2].strip() if text.endswith('*/') else text[2:].strip()
            comments.append((start_line, '-- ' + content.replace('\n', ' ')))
        # Line comment
        elif source[i] == '/' and i + 1 < n and source[i + 1] == '/':
            start_line = line_num
            i += 2
            text_parts = []
            while i < n and source[i] != '\n':
                text_parts.append(source[i])
                i += 1
            content = ''.join(text_parts).strip()
            comments.append((start_line, '-- ' + content))
        elif source[i] == '"':
            # Skip string literal
            i += 1
            while i < n:
                if source[i] == '\\' and i + 1 < n:
                    i += 2
                elif source[i] == '"':
                    i += 1
                    break
                else:
                    if source[i] == '\n':
                        line_num += 1
                    i += 1
        elif source[i] == '\n':
            line_num += 1
            i += 1
        else:
            i += 1
    return comments

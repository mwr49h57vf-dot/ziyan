"""Lexical dependency contract mirrored by ZiYanScriptDependencies.h.

Comments and explanatory strings are data. Dynamic loaders are unverified.
This does not sandbox Lua or replace its parser.
"""
import re

NEEDED = ('phase_login', 'phase_role_select', 'phase_enter_game', 'phase_auto_battle', 'runApp')


def tokens(source):
    p = 0
    while p < len(source):
        if source[p].isspace():
            p += 1
            continue
        comment = source.startswith('--', p)
        if comment:
            p += 2
        long = re.match(r'\[(=*)\[', source[p:])
        if long:
            start = p + len(long[0])
            closing = ']' + long[1] + ']'
            end = source.find(closing, start)
            if end < 0:
                raise ValueError('malformed_token')
            if not comment:
                yield 'string', source[start:end].removeprefix('\n')
            p = end + len(closing)
            continue
        if comment:
            while p < len(source) and source[p] not in '\r\n':
                p += 1
            continue
        char = source[p]
        if char in '\'"':
            quote, value = char, []
            p += 1
            while p < len(source) and source[p] != quote:
                char = source[p]
                p += 1
                if char in '\r\n':
                    raise ValueError('malformed_token')
                if char == '\\':
                    if p >= len(source):
                        raise ValueError('malformed_token')
                    char = source[p]
                    p += 1
                    if char == 'z':
                        while p < len(source) and source[p].isspace():
                            p += 1
                        continue
                    if char.isdigit() and char.isascii():
                        rest = re.match(r'[0-9]{0,2}', source[p:])[0]
                        p += len(rest)
                        code = int(char + rest)
                        char = chr(code) if 0 < code < 128 else '?'
                    elif char == 'x':
                        digits = source[p:p+2]
                        if len(digits) != 2 or not re.fullmatch('[0-9a-fA-F]{2}', digits):
                            raise ValueError('malformed_token')
                        p += 2
                        code = int(digits, 16)
                        char = chr(code) if 0 < code < 128 else '?'
                    elif char == 'u' and source[p:p+1] == '{':
                        escape = re.match(r'\{([0-9a-fA-F]+)\}', source[p:])
                        if not escape:
                            raise ValueError('malformed_token')
                        p += len(escape[0])
                        code = int(escape[1], 16)
                        char = chr(code) if 0 < code < 128 else '?'
                    else:
                        char = {'n':'\n','r':'\r','t':'\t'}.get(char, char)
                value.append(char)
            if p >= len(source):
                raise ValueError('malformed_token')
            p += 1
            yield 'string', ''.join(value)
            continue
        identifier = re.match(r'[A-Za-z_][A-Za-z_0-9]*', source[p:])
        if identifier:
            p += len(identifier[0])
            yield 'identifier', identifier[0]
            continue
        p += 1
        yield 'symbol', char


def dependency_contract(source):
    identifiers = set()
    try:
        stream = list(tokens(source))
        index = 0
        after_function = False
        while index < len(stream):
            kind, value = stream[index]
            index += 1
            if kind != 'identifier':
                after_function = False
                continue
            lookahead = stream[index] if index < len(stream) else None
            if value in NEEDED[:4] and after_function and lookahead == ('symbol','('):
                identifiers.add(value)
            if value == 'runApp' and not after_function and lookahead == ('symbol','('):
                identifiers.add(value)
            after_function = value == 'function'
            if value in ('load','loadstring','_G','_ENV','getfenv','setfenv','package'):
                return 3, identifiers
            if value == 'TSLib':
                return 1, identifiers
            if value in ('require', 'dofile', 'loadfile'):
                parenthesized = index < len(stream) and stream[index] == ('symbol', '(')
                if parenthesized:
                    index += 1
                if index >= len(stream) or stream[index][0] != 'string' or len(stream[index][1].encode('utf8')) > 255:
                    return 3, identifiers
                module = stream[index][1].replace('\\','/').rsplit('/',1)[-1]
                index += 1
                if any(module == name or module.startswith(name+'.') for name in ('TSLib','ts','sz')):
                    return 1, identifiers
                if parenthesized and (index >= len(stream) or stream[index] != ('symbol', ')')):
                    return 3, identifiers
                if not parenthesized and index < len(stream) and stream[index] == ('symbol', '.'):
                    return 3, identifiers
        return 0, identifiers
    except ValueError:
        return 2, identifiers

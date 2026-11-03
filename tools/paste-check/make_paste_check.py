"""Makes large paste-size test files (32, 48, 64, 96 MB; GitHub refuses files over 100 MB) and
writes their SHA-256 into check-paste.ps1, which tells whether a saved paste arrived whole and,
if not, up to which line. The files go on the branch paste-test-large only.

    python3 tools/paste-check/make_paste_check.py <output folder>

Line format (CRLF): first line "PASTECHECK v2 size=<n>MB lines=<lines>", then
"L<i, 8 digits> <68 characters of the base64 alphabet made from i>", last line "END lines=<lines>".
"""
import hashlib
import pathlib
import sys

ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
BODY = 68
LINE_BYTES = 1 + 8 + 1 + BODY + 2
SIZES = (32, 48, 64, 96)


def line_text(i):
    x = ((i * 2654435761) & 0xFFFFFFFF) ^ 0x9E3779B9
    out = []
    for _ in range(BODY):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        out.append(ALPHA[x & 63])
    return f"L{i:08d} " + "".join(out)


def main():
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    sums = []
    for mb in SIZES:
        lines = (mb * 1_000_000) // LINE_BYTES
        body = [f"PASTECHECK v2 size={mb}MB lines={lines}"] + [line_text(i) for i in range(1, lines + 1)] + [f"END lines={lines}"]
        text = "\n".join(body) + "\n"
        (out / f"paste_{mb:02d}MB.txt").write_bytes(text.replace("\n", "\r\n").encode("ascii"))
        # the check compares the text with line ends made LF, so CRLF / LF both pass
        sums.append(f"    '{mb}' = '{hashlib.sha256(text.encode('ascii')).hexdigest()}'")
        print(mb, "MB", lines, "lines")
    ps = pathlib.Path(__file__).with_name("check-paste.ps1")
    s = ps.read_text(encoding="ascii")
    start = s.index("$expected = @{") + len("$expected = @{")
    end = s.index("}", start)
    s = s[:start] + "\r\n" + "\r\n".join(sums) + "\r\n" + s[end:]
    ps.write_bytes(s.replace("\r\n", "\n").replace("\n", "\r\n").encode("ascii"))


if __name__ == "__main__":
    main()

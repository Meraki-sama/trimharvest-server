import sys, re

def strip_comments(path):
    out = []
    for line in open(path, encoding='utf-8'):
        # cut at first // (no // inside strings in these files)
        cut = line.find('//')
        if cut != -1:
            line = line[:cut]
        line = line.rstrip('\n')
        if line.strip() == '':
            continue
        out.append(line)
    return out

orig, new = sys.argv[1], sys.argv[2]
a, b = strip_comments(orig), strip_comments(new)
if a == b:
    print(f"OK: code identical ({len(a)} code lines) {orig} <-> {new}")
else:
    print(f"DIFF in {orig} <-> {new}")
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else "<none>"
        y = b[i] if i < len(b) else "<none>"
        if x != y:
            print(f"  [{i}] ORIG: {x!r}")
            print(f"  [{i}] NEW : {y!r}")

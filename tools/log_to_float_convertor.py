import sys
import os
import re
import struct

def hex_to_float(match):
    f_val = struct.unpack('!f', bytes.fromhex(match.group(0)))[0]
    return f"{f_val:.6f}"

def process_line(line):
    clean_line = line.replace("GPU debug: RefitOrientedBounds3_1.hlsl:851 ", "").strip()
    if clean_line:
        print(re.sub(r'\b[0-9a-fA-F]{8}\b', hex_to_float, clean_line))

if not sys.stdin.isatty():
    # 파이프(|) 등 표준 입력
    for line in sys.stdin:
        process_line(line)
elif len(sys.argv) > 1:
    # 인자가 1개이고 실제 존재하는 파일인 경우
    if len(sys.argv) == 2 and os.path.isfile(sys.argv[1]):
        with open(sys.argv[1], 'r', encoding='utf-8') as f:
            for line in f:
                process_line(line)
    else:
        # 큰따옴표 없이 여러 단어로 입력된 경우 하나의 문자열로 병합
        input_data = " ".join(sys.argv[1:])
        process_line(input_data)
else:
    print("사용법: python script.py <파일경로 또는 로그 문자열>")
import struct
import math
import argparse
import matplotlib.pyplot as plt

ObbStage1Lut = [
    0x162c0ad6000019, 0x16ac02d6000019, 0x11440c51000019, 0x11c40451000019, 0xb580d8b000019,
    0xbd8058b000019,  0x640e40000019,   0xe40640000019,   0x1602b01900b016, 0x1600b01902b016,
    0x11031019011011, 0x11011019031011, 0xb03601901600b,  0xb01601903600b,  0x39019019000,
    0x19019039000,    0x190000162c0ad6, 0x19000016ac02d6, 0x19000011440c51, 0x19000011c40451,
    0x1900000b580d8b, 0x1900000bd8058b, 0x19000000640e40, 0x19000000e40640, 0x18066058186996,
    0x180460589a6196, 0x140ac09430cb11, 0x1408c094b2c311, 0x101ef1d03cfbcb, 0x101cf1d0bef3cb,
    0xc33130c451c40,  0xc31130cc71440,  0x188468581a6996, 0x18866858986196, 0x1488c89432cb11,
    0x148ac894b0c311, 0x109cf9d03efbcb, 0x109ef9d0bcf3cb, 0xcb11b0c471c40,  0xcb31b0cc51440,
    0x18181996181998, 0x18981196981198, 0x14302b11302b14, 0x14b02311b02314, 0x103c7bcb3c7bd0,
    0x10bc73cbbc73d0, 0xc44cc4044cc4c,  0xcc4c440c4c44c,  0x181a19969a1198, 0x189a11961a1998,
    0x14322b11b22314, 0x14b22311322b14, 0x103e7bcbbe73d0, 0x10be73cb3e7bd0, 0xc46cc40c6c44c,
    0xcc6c44046cc4c,  0x161a6998046058, 0x16986198066058, 0x1132cb1408c094, 0x11b0c3140ac094,
    0xb3efbd01cf1d0,  0xbbcf3d01ef1d0,  0x471c4c31130c,   0xc5144c33130c,   0x169a6198846858,
    0x16186998866858, 0x11b2c31488c894, 0x1130cb148ac894, 0xbbef3d09cf9d0,  0xb3cfbd09ef9d0,
    0xc7144cb11b0c,   0x451c4cb31b0c,   0x171638d71458d7, 0x178c51578e3157, 0x13368a1334da13,
    0x13a0d353a28353, 0xe4a9a4e492a4e,  0xea5248ea6948e,  0xa56490a55590a,  0xa91554a92454a,
    0x178e51570c3957, 0x171438d79650d7, 0x13a2d353208b53, 0x13348a13b6d213, 0xea7248e249c8e,
    0xe489a4ecb224e,  0xa93554a104d4a,  0xa54490ad7510a,  0x170c59570e3957, 0x179630d79450d7,
    0x1320db53228b53, 0x13b68213b4d213, 0xe252c8e269c8e,  0xeca924ec9224e,  0xa115d4a124d4a,
    0xad6410ad5510a,  0x179430d71658d7, 0x170e59578c3157, 0x13b4821336da13, 0x1322db53a08353,
    0xec8924e4b2a4e,  0xe272c8ea4948e,  0xad4410a57590a,  0xa135d4a90454a
]

ObbStage2Lut = [
    0x00000000, 0x3d1be50c, 0x3e15f61a, 0x3e484336, 0x3e79df93, 0x3e7c3a3a, 0x3e8a8bd4, 0x3e9e0875,
    0x3e9f0938, 0x3ea7bf1b, 0x3eaaaaab, 0x3ec3ef15, 0x3f000000, 0x3f01814f, 0x3f16a507, 0x3f273d75,
    0x3f30fbc5, 0x3f3504f3, 0x3f3d3a87, 0x3f4e034d, 0x3f5a827a, 0x3f692290, 0x3f6c835e, 0x3f73023f,
    0x3f7641af, 0x3f800000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000
]

def decode_matrices():
    matrices = []
    for stage1 in ObbStage1Lut:
        mat = []
        for row in range(3):
            row_vals = []
            for col in range(3):
                shift = (18 * row) + (6 * col)
                s2_idx = (stage1 >> shift) & 0x3f
                val = ObbStage2Lut[s2_idx & 0x1f] | ((s2_idx >> 5) << 31)
                f_val = struct.unpack('<f', struct.pack('<I', val))[0]
                row_vals.append(f_val)
            mat.append(row_vals)
        matrices.append(mat)
    return matrices

def mat_mul(A, B):
    return [[sum(a * b for a, b in zip(A_row, B_col)) for B_col in zip(*B)] for A_row in A]

# 벡터 * 행렬 (3D)
def vec_mul(mat, vec):
    return [sum(mat[r][c] * vec[c] for c in range(3)) for r in range(3)]

def get_rotation_matrix(rot_x, rot_y, rot_z):
    c, s = math.cos(math.pi / 4), math.sin(math.pi / 4)
    I = [[1,0,0], [0,1,0], [0,0,1]]
    
    Rx = [[1, 0, 0], [0, c, -s], [0, s, c]] if rot_x else I
    Ry = [[c, 0, s], [0, 1, 0], [-s, 0, c]] if rot_y else I
    Rz = [[c, -s, 0], [s, c, 0], [0, 0, 1]] if rot_z else I
    
    return mat_mul(mat_mul(Rx, Ry), Rz)

def find_closest_index_hemisphere(target, matrices):
    best_idx = 0
    best_sim = -1.0
    for i, m in enumerate(matrices):
        sim = 0.0
        for r in range(3):
            dot_val = sum(target[r][c] * m[r][c] for c in range(3))
            sim += abs(dot_val)
        if sim > best_sim:
            best_sim = sim
            best_idx = i
    return best_idx

def is_axis_aligned(mat):
    # 행렬의 각 행에 1 또는 -1이 정확히 1개, 0이 정확히 2개 있는지 검사 (오차 허용)
    # 이를 만족하면 월드 축에 완벽히 정렬된 24가지 경우 중 하나입니다.
    for row in mat:
        ones = sum(1 for val in row if abs(abs(val) - 1.0) < 1e-4)
        zeros = sum(1 for val in row if abs(val) < 1e-4)
        if ones != 1 or zeros != 2:
            return False
    return True

def get_matrix_alignment(mat_a, mat_b):
    # 90도 회전(축 스왑 및 부호 반전)에 무관하게 두 행렬의 확장 방향 유사도를 측정
    align_sum = 0
    for r_a in mat_a:
        # mat_a의 각 축에 대해 mat_b의 축들 중 가장 평행한(내적 절대값이 큰) 것을 찾음
        max_dot = max(abs(sum(r_a[k] * r_b[k] for k in range(3))) for r_b in mat_b)
        align_sum += max_dot
    return align_sum

def find_most_twisted_index(valid_matrices, all_matrices, fixed_indices):
    if not valid_matrices:
        # 8개 모두 0x7f인 예외 상황 시 기준점 제공 (기본 행렬 사용)
        valid_matrices = [all_matrices[0]]

    best_idx = -1
    min_alignment = float('inf')

    for i, cand_mat in enumerate(all_matrices):
        if i in fixed_indices:
            continue
        
        # 현재 배열의 유효한 매트릭스들과의 유사도를 모두 합산
        total_alignment = sum(get_matrix_alignment(cand_mat, v_mat) for v_mat in valid_matrices)
        
        # 유사도 합이 가장 작음 == 가장 비틀려 있음
        if total_alignment < min_alignment:
            min_alignment = total_alignment
            best_idx = i

    return best_idx

# 파라미터 추가
def generate_lut(disable_invalid=False, final_mode=False):
    matrices = decode_matrices()
    fixed_axis_aligned_indices = {6, 7, 14, 15, 22, 23}
    
    print("static const uint8_t ObbRotIndexLut[104][8] = {")
    for i, mat in enumerate(matrices):
        row_indices = []
        row_valid_matrices = [] # 유효한 매트릭스 보관용
        invalid_positions = []  # 0x7f 위치 추적용

        for mask in range(8):
            rot_mat = get_rotation_matrix(mask & 1, mask & 2, mask & 4)
            rotated_mat = mat_mul(mat, rot_mat) 
            
            is_invalid = False
            closest_idx = find_closest_index_hemisphere(rotated_mat, matrices)

            if not disable_invalid:
                if is_axis_aligned(rotated_mat) or closest_idx in fixed_axis_aligned_indices:
                    is_invalid = True

            if is_invalid:
                row_indices.append("0x7f")
                invalid_positions.append(mask)
            else:
                row_indices.append(str(closest_idx))
                # 비교를 위해 원본 104개 중 선택된 매트릭스를 저장
                row_valid_matrices.append(matrices[closest_idx])

        # --- [-f 옵션 로직 추가] 0x7f를 가장 비틀린 인덱스로 대체 ---
        if final_mode and invalid_positions:
            twisted_idx = find_most_twisted_index(row_valid_matrices, matrices, fixed_axis_aligned_indices)
            for pos in invalid_positions:
                row_indices[pos] = str(twisted_idx)
        # -----------------------------------------------------------
                
        line = "    {" + ", ".join(row_indices) + "}"
        print(line + ("," if i < 103 else ""))
    print("};")

def visualize_8_matrices(idx1, fig, disable_invalid=False, final_mode=False):
    all_matrices = decode_matrices() # 전체 후보 행렬 리스트
    if idx1 < 0 or idx1 >= len(all_matrices):
        print(f"Error: Base index {idx1} is out of bounds.")
        return

    base_mat = all_matrices[idx1]
    fixed_axis_aligned_indices = {6, 7, 14, 15, 22, 23}

    # 1. 8개 마스크 결과 및 대체 인덱스 계산
    row_indices = []
    row_valid_matrices = []
    invalid_positions = []
    original_result_matrices = [] # 마스크만 곱해진 원래 행렬들

    for mask in range(8):
        rot_mat = get_rotation_matrix(mask & 1, mask & 2, mask & 4)
        result_mat = mat_mul(base_mat, rot_mat)
        original_result_matrices.append(result_mat)
        
        closest_idx = find_closest_index_hemisphere(result_mat, all_matrices)

        is_invalid = False
        if not disable_invalid:
            if is_axis_aligned(result_mat) or closest_idx in fixed_axis_aligned_indices:
                is_invalid = True

        if is_invalid:
            row_indices.append("0x7f")
            invalid_positions.append(mask)
        else:
            row_indices.append(str(closest_idx))
            row_valid_matrices.append(all_matrices[closest_idx])

    # -f 모드: 0x7f 자리를 비틀린 인덱스로 치환
    twisted_idx = -1
    if final_mode and invalid_positions:
        twisted_idx = find_most_twisted_index(row_valid_matrices, all_matrices, fixed_axis_aligned_indices)
        for pos in invalid_positions:
            row_indices[pos] = str(twisted_idx)

    # 2. 시각화 렌더링 루프
    fig.clf()
    hx, hy, hz = 1.5, 2.5, 0.75 
    corners = [[-hx,-hy,-hz], [hx,-hy,-hz], [hx,hy,-hz], [-hx,hy,-hz],
               [-hx,-hy,hz], [hx,-hy,hz], [hx,hy,hz], [-hx,hy,hz]]
    edges = [(0,1), (1,2), (2,3), (3,0), (4,5), (5,6), (6,7), (7,4), (0,4), (1,5), (2,6), (3,7)]

    for mask in range(8):
        final_val = row_indices[mask]
        
        # [중요] 렌더링할 행렬 결정
        # 0x7f가 아니고 -f 모드에 의해 대체된 칸이라면, '가장 비틀린 행렬'을 가져와 렌더링
        if final_mode and mask in invalid_positions:
            render_mat = all_matrices[int(final_val)]
            is_replacement = True
        else:
            render_mat = original_result_matrices[mask]
            is_replacement = False
        
        is_invalid_display = (final_val == "0x7f")
        ax = fig.add_subplot(2, 4, mask + 1, projection='3d')
        
        # 타이틀 설정
        title_text = f"Mask {mask} (R: {mask&1}, {mask&2>>1}, {mask&4>>2})"
        if not is_invalid_display:
            suffix = " (Twisted Replace)" if is_replacement else ""
            title_text += f"\n-> Idx: {final_val}{suffix}"
        ax.set_title(title_text, fontsize=9)

        # 텍스트 박스에 행렬 값 표시
        mat_str = "\n".join([f"[{r[0]:.2f}, {r[1]:.2f}, {r[2]:.2f}]" for r in render_mat])
        ax.text2D(0.05, 0.95, mat_str, transform=ax.transAxes, fontsize=7,
                  verticalalignment='top', bbox=dict(boxstyle='round', facecolor='white', alpha=0.7))
        
        ax.set_xlim([-3, 3]); ax.set_ylim([-3, 3]); ax.set_zlim([-3, 3])
        
        if is_invalid_display:
            ax.text2D(0.5, 0.5, "INVALID\n(0x7f)", color='red', fontsize=14, weight='bold', ha='center', va='center', transform=ax.transAxes)
            alpha_val = 0.1
        else:
            # 대체된 행렬은 파란색 계열로 표시하여 구분 가능하게 함
            color_style = 'dodgerblue' if is_replacement else 'gray'
            alpha_val = 1.0

            # 박스 및 축 렌더링
            rot_corners = [vec_mul(render_mat, c) for c in corners]
            for p1, p2 in edges:
                c1, c2 = rot_corners[p1], rot_corners[p2]
                ax.plot([c1[0], c2[0]], [c1[1], c2[1]], [c1[2], c2[2]], color=color_style, alpha=alpha_val)
            
            # 로컬 축 (Quiver)
            lx = vec_mul(render_mat, [hx*1.3, 0, 0])
            ly = vec_mul(render_mat, [0, hy*1.3, 0])
            lz = vec_mul(render_mat, [0, 0, hz*1.3])
            ax.quiver(0,0,0, *lx, color='r', arrow_length_ratio=0.15)
            ax.quiver(0,0,0, *ly, color='g', arrow_length_ratio=0.15)
            ax.quiver(0,0,0, *lz, color='b', arrow_length_ratio=0.15)
            
    plt.tight_layout()
    plt.pause(0.01)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OBB LUT Generator or Matrix Visualizer")
    parser.add_argument('-g', '--generate', action='store_true', help="Generate LUT mode")
    # -f, --final 옵션 등록
    parser.add_argument('-f', '--final', action='store_true', help="Final mode: 0x7f를 가장 비틀린 인덱스로 대체")
    parser.add_argument('-og', action='store_true', help="Disable 0x7f invalidation")
    # 기존 -p 대신 사용하시는 -gui 옵션
    parser.add_argument('-gui', nargs='?', const=-1, type=int, help="Print & Visualize mode (Interactive)")
    parser.add_argument('-w', '--write_all', action='store_true', help="Print all decoded matrices")

    args = parser.parse_args()
    
    if args.generate:
        # args.f 대신 args.final 사용 (주석: -f는 final_mode를 활성화함)
        generate_lut(disable_invalid=args.og, final_mode=args.final)
    elif args.write_all:
        matrices = decode_matrices()
        axis_aligned_indices = []
        
        print(f"=== Decoded {len(matrices)} Matrices (Index 0 to 103) ===")
        for i, mat in enumerate(matrices):
            aligned = is_axis_aligned(mat)
            if aligned:
                axis_aligned_indices.append(i)
            
            status = "[Axis-Aligned]" if aligned else ""
            print(f"Matrix Index [{i}] {status}:")
            for row in mat:
                print(f"  [{row[0]:.6f}, {row[1]:.6f}, {row[2]:.6f}]")
            print("-" * 30)
        
        print("\n=== Summary of Axis-Aligned Indices ===")
        print(f"Total count: {len(axis_aligned_indices)}")
        print(f"Indices: {axis_aligned_indices}")
    else:
        print("=== 인터랙티브 시각화 모드 ===")
        
        plt.ion()
        main_fig = plt.figure(figsize=(16, 8))
        
        # args.f 대신 args.final 사용
        if args.gui is not None and args.gui >= 0:
            visualize_8_matrices(args.gui, main_fig, disable_invalid=args.og, final_mode=args.final)
            
        while True:
            val = input("\nBase Index 입력 (0-103) [종료: q]: ").strip()
            if val.lower() == 'q':
                break
            try:
                idx = int(val)
                # args.f 대신 args.final 사용
                visualize_8_matrices(idx, main_fig, disable_invalid=args.og, final_mode=args.final)
            except ValueError:
                print("올바른 숫자(0~103)나 'q'를 입력하세요.")
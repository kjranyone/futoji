# -*- coding: utf-8 -*-
"""ONNX の出力ログットに定数シフトを焼き込む。

アプリは output > 0 でマスク化するので、最終 Conv (1ch 出力) の bias を
-t する == 閾値を t に上げる。アプリ側のコード変更は不要。

使い方: python tools/shift_onnx_threshold.py <in.onnx> <out.onnx> <t>
"""

import sys

import numpy as np
import onnx


def main():
    src, dst, t = sys.argv[1], sys.argv[2], float(sys.argv[3])
    model = onnx.load(src)

    # 出力に一番近い Conv (head) を探す: 1 出力チャネルの Conv のうち最後のもの
    convs = [n for n in model.graph.node if n.op_type == "Conv"]
    head = None
    for n in reversed(convs):
        # 出力チャネル数は weight の shape[0]
        for init in model.graph.initializer:
            if init.name == n.input[1]:
                if list(init.dims)[0] == 1:
                    head = n
                    break
        if head:
            break
    if head is None:
        raise SystemExit("1 出力チャネルの Conv が見つからない")

    if len(head.input) < 3 or head.input[2] == "":
        raise SystemExit("head Conv に bias がない (bias を新設する必要がある)")

    for i, init in enumerate(model.graph.initializer):
        if init.name == head.input[2]:
            bias = onnx.numpy_helper.to_array(init).astype(np.float32)
            new_init = onnx.numpy_helper.from_array(
                (bias - t).astype(np.float32), init.name)
            model.graph.initializer[i].CopyFrom(new_init)
            print(f"{init.name}: bias -= {t} (shape {bias.shape})")
            break

    onnx.checker.check_model(model)
    onnx.save(model, dst)
    print("saved:", dst)


if __name__ == "__main__":
    main()

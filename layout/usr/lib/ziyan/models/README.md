# ZiYan findcolor_int8（自研 · 免费）

- **许可证**：与 ZiYan 工程同权；非第三方闭源权重。
- **结构**：Input → AbsVal（无训练权重；跑通 NCNN `load_param` + Extractor 冒烟）。
- **坐标**：Extractor 仅加载时冒烟；**找色坐标仍走 LOCK ColorMatch 公式**（禁止模型瞎报）。
- **用途**：T4 `has_weight=1` + `loaded=1` 验收；真 ML 找色模型需另训，不可用触动私有模型。

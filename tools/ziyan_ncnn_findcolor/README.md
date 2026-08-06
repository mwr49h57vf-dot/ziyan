# ziyan_ncnn_findcolor（终稿 P2-13 / 8-148）

## 硬锁

`LOCK_FINDCOLOR`：相似度 / fuzzy / 邻域抗锯齿公式 **禁止改语义**。

## 8-148/149 落地（真链 NCNN + NEON + 粗扫）

| 项 | 说明 |
|----|------|
| 静态库 | `vendor/ncnn-ios`（BSD-3 Tencent/ncnn 20241226 ios arm64）+ openmp |
| 入口 | `ZiYanNcnnFindMulti` → framecap `findMulti`；关：`.ziyan_ncnn_off` |
| NCNN 作用 | 一次性 `set_cpu_powersave` / OMP=1；触达 `ncnn::Mat`；**不再每 find 拷贝整帧** |
| 匹配核 | 仍 `ZiYanColorMatchFindMulti`（NEON + 并行条带 + **8-149 scaleHint 粗扫+精修**） |
| via 标记 | JSON / `.ziyan_find_via` → `ncnn`（关闭 NCNN 时回落 `daemon`） |
| 禁 | Vulkan / ANE / 替换 fuzzy 公式的神经网络权重 |

## NEON（8-147）

| 项 | 说明 |
|----|------|
| 实现 | `ZiYanColorMatch.m`：`ZCM_neonMainRejectMask` 4 像素主色初筛 |
| 关闭 | `touch $VAR/.ziyan_color_neon_off` 后重启 framecap |

## 权重（可选后续）

真·int8 模型路径预留本目录；未完成对照前 **禁止** 替换 `findMultiColorInRegionFuzzy` 默认语义。
优先免费开源权重（Hugging Face / GitHub），接入前须说明许可证并四机对照 PASS。

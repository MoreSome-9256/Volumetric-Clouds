# URP Advanced Volumetric Clouds (Unity 2022.3+)

基于 Unity URP 框架手写的实时高质量体积云渲染系统。本项目为南京大学夏令营科研实践成果。

## 🌟 特性迭代阶段

- **V1 - Baseline:** 基础等步长双重循环，程序化 WeatherMap 驱动，应用屏幕空间高频白噪声打乱步进。
- **V2 - Physics Advanced:** 基于 RTE 扩散近似模型推导出的 $\phi_{fwd}$ 物理漫射积分场，支持 3-Octave 多重散射，彻底消灭厚云死黑。引入**自适应双步长追踪**，剔除空白带宽开销。
- **V3 - Stylized:** 探索唯美二次元动漫渲染风格，引入Top/Bottom形态学包络线、迎光面方向性粉末效应（银边高光）。
- **LOD:** 应用**近精远粗的自适应体积 LOD 调度与高频3D噪声视距裁剪**，全分辨率4K开销大幅收敛。

## 🛠️ 项目使用说明
1. 将 `Blue Noise` 的 Filter Mode 设为 Point，Wrap Mode 设为 Repeat。
2. 在场景的后处理 Volume 组件中一键切换菜单中的枚举（V1/V2/V3/LOD），即可直观查阅不同图形学逻辑带来的视觉变化。

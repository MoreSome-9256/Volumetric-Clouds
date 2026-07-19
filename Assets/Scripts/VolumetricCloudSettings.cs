using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

[Serializable, VolumeComponentMenu("Custom/Volumetric Clouds Advanced")]
public class VolumetricCloudSettings : VolumeComponent, IPostProcessComponent
{
    [Header("基本设置 (Basic)")]
    public BoolParameter enable = new BoolParameter(false);

    [Header("形状与分布 (Shape)")]
    public ClampedFloatParameter cloudDensity = new ClampedFloatParameter(0.5f, 0f, 2f);
    public TextureParameter weatherMap = new TextureParameter(null);
    public FloatParameter weatherMapTiling = new FloatParameter(0.0001f);

    [Header("云层高度与类型 (Cloud Types)")]
    public Vector4Parameter cloudMinMax = new Vector4Parameter(new Vector4(1500f, 4000f, 0f, 0f));
    // X: 最小高度比例, Y: 最大高度比例, Z: 边缘羽化
    public Vector3Parameter stratusInfo = new Vector3Parameter(new Vector3(0.1f, 0.4f, 0.2f));
    public Vector3Parameter cumulusInfo = new Vector3Parameter(new Vector3(0.15f, 0.8f, 0.2f));

    [Header("3D 噪声纹理 (Noise Textures)")]
    public Texture3DParameter baseNoiseTex = new Texture3DParameter(null);
    public FloatParameter baseNoiseScale = new FloatParameter(0.001f);
    public ClampedFloatParameter baseShapeDetailEffect = new ClampedFloatParameter(0.5f, 0f, 1f);

    public Texture3DParameter detailNoiseTex = new Texture3DParameter(null);
    public FloatParameter detailNoiseScale = new FloatParameter(0.005f);
    public ClampedFloatParameter detailEffect = new ClampedFloatParameter(0.5f, 0f, 1f);

    [Header("风场控制 (Wind)")]
    public Vector3Parameter windDirection = new Vector3Parameter(new Vector3(1, 0, 0));
    public FloatParameter windSpeed = new FloatParameter(50f);

    [Header("光照与色彩 (Lighting & Color)")]
    public ColorParameter colorBright = new ColorParameter(Color.white, true, true, true);
    public ColorParameter colorDark = new ColorParameter(new Color(0.2f, 0.2f, 0.2f), true, true, true);
    public ClampedFloatParameter cloudAbsorb = new ClampedFloatParameter(0.5f, 0f, 4f);
    public ClampedFloatParameter darknessThreshold = new ClampedFloatParameter(0.3f, 0f, 1f);

    [Header("散射相位 (Scattering)")]
    public ClampedFloatParameter scatterForward = new ClampedFloatParameter(0.5f, 0f, 0.99f);
    public ClampedFloatParameter scatterForwardIntensity = new ClampedFloatParameter(1.0f, 0f, 1f);
    public ClampedFloatParameter scatterBackward = new ClampedFloatParameter(0.4f, 0f, 0.99f);
    public ClampedFloatParameter scatterBackwardIntensity = new ClampedFloatParameter(0.4f, 0f, 1f);

    [Header("高级物理光照 (Advanced Physics Lighting)")]
    public ClampedFloatParameter phiFwdIntensity = new ClampedFloatParameter(1.5f, 0f, 5f);
    public ClampedFloatParameter phiFwdCompress = new ClampedFloatParameter(0.8f, 0.01f, 3f);
    public ClampedFloatParameter coneRatio = new ClampedFloatParameter(2.0f, 1.0f, 4.0f);

    [Header("性能控制 (Performance)")]
    // 🚀 [蓝噪声修改] 新增蓝噪声贴图槽位
    public TextureParameter blueNoiseTex = new TextureParameter(null);

    public FloatParameter stepSize = new FloatParameter(30f);
    public IntParameter maxSteps = new IntParameter(64);
    public IntParameter lightSteps = new IntParameter(6);
    public FloatParameter earthRadius = new FloatParameter(6371000f);

    [Header("多重散射控制 (Multi-Scattering)")]
    [Tooltip("消光衰减率 (Attenuation)：越小高阶光路穿透越深，云越通透")]
    public ClampedFloatParameter msAttenuation = new ClampedFloatParameter(0.5f, 0.01f, 1.0f);
    [Tooltip("散射能量贡献 (Contribution)：越大云内部越亮越白")]
    public ClampedFloatParameter msContribution = new ClampedFloatParameter(0.5f, 0.0f, 1.0f);
    [Tooltip("相位偏心率衰减 (Eccentricity)：越小高阶越趋于各向同性")]
    public ClampedFloatParameter msEccentricity = new ClampedFloatParameter(0.5f, 0.0f, 1.0f);

    public bool IsActive() => enable.value;
    public bool IsTileCompatible() => false;
}
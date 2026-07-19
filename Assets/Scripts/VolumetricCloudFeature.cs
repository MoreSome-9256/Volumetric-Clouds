using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class VolumetricCloudFeature : ScriptableRendererFeature
{
    class CloudRenderPass : ScriptableRenderPass
    {
        public Material cloudMaterial;
        private RTHandle tempTarget;

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            RenderingUtils.ReAllocateIfNeeded(ref tempTarget, desc, name: "_TempCloudTarget");
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (cloudMaterial == null) return;
            var cloudSettings = VolumeManager.instance.stack.GetComponent<VolumetricCloudSettings>();
            if (cloudSettings == null || !cloudSettings.IsActive()) return;

            var cameraColorTarget = renderingData.cameraData.renderer.cameraColorTargetHandle;
            if (cameraColorTarget == null || cameraColorTarget.rt == null) return;

            CommandBuffer cmd = CommandBufferPool.Get("Volumetric Clouds Advanced");
            Camera cam = renderingData.cameraData.camera;

            // --- 传递基础与形态参数 ---
            cloudMaterial.SetVector("_CloudMinMax", cloudSettings.cloudMinMax.value);
            cloudMaterial.SetFloat("_CloudDensity", cloudSettings.cloudDensity.value);

            if (cloudSettings.weatherMap.value != null)
                cloudMaterial.SetTexture("_WeatherMap", cloudSettings.weatherMap.value);
            cloudMaterial.SetFloat("_WeatherMapTiling", cloudSettings.weatherMapTiling.value);

            cloudMaterial.SetVector("_StratusInfo", cloudSettings.stratusInfo.value);
            cloudMaterial.SetVector("_CumulusInfo", cloudSettings.cumulusInfo.value);

            // --- 传递噪声参数 ---
            if (cloudSettings.baseNoiseTex.value != null)
                cloudMaterial.SetTexture("_BaseNoiseTex", cloudSettings.baseNoiseTex.value);
            cloudMaterial.SetFloat("_BaseNoiseScale", cloudSettings.baseNoiseScale.value);
            cloudMaterial.SetFloat("_BaseShapeDetailEffect", cloudSettings.baseShapeDetailEffect.value);

            if (cloudSettings.detailNoiseTex.value != null)
                cloudMaterial.SetTexture("_DetailNoiseTex", cloudSettings.detailNoiseTex.value);
            cloudMaterial.SetFloat("_DetailNoiseScale", cloudSettings.detailNoiseScale.value);
            cloudMaterial.SetFloat("_DetailEffect", cloudSettings.detailEffect.value);

            // --- 风场 ---
            cloudMaterial.SetVector("_WindDirection", cloudSettings.windDirection.value.normalized);
            cloudMaterial.SetFloat("_WindSpeed", cloudSettings.windSpeed.value);

            // --- 光照与颜色 ---
            cloudMaterial.SetColor("_ColorBright", cloudSettings.colorBright.value);
            cloudMaterial.SetColor("_ColorDark", cloudSettings.colorDark.value);
            cloudMaterial.SetFloat("_CloudAbsorb", cloudSettings.cloudAbsorb.value);
            cloudMaterial.SetFloat("_DarknessThreshold", cloudSettings.darknessThreshold.value);

            cloudMaterial.SetFloat("_ScatterForward", cloudSettings.scatterForward.value);
            cloudMaterial.SetFloat("_ScatterForwardIntensity", cloudSettings.scatterForwardIntensity.value);
            cloudMaterial.SetFloat("_ScatterBackward", cloudSettings.scatterBackward.value);
            cloudMaterial.SetFloat("_ScatterBackwardIntensity", cloudSettings.scatterBackwardIntensity.value);

            // 传递高级光照参数到 Shader
            cloudMaterial.SetFloat("_PhiFwdIntensity", cloudSettings.phiFwdIntensity.value);
            cloudMaterial.SetFloat("_PhiFwdCompress", cloudSettings.phiFwdCompress.value);
            cloudMaterial.SetFloat("_ConeRatio", cloudSettings.coneRatio.value);

            // --- 性能 ---
            // 🚀 [蓝噪声修改] 将蓝噪声贴图传递给 Shader
            if (cloudSettings.blueNoiseTex.value != null)
            {
                cloudMaterial.SetTexture("_BlueNoiseTex", cloudSettings.blueNoiseTex.value);
            }

            cloudMaterial.SetFloat("_StepSize", cloudSettings.stepSize.value);
            cloudMaterial.SetInt("_MaxSteps", cloudSettings.maxSteps.value);
            cloudMaterial.SetInt("_LightSteps", cloudSettings.lightSteps.value);

            // 🚀 阶段四新增：传递多重散射参数到 Shader
            cloudMaterial.SetFloat("_MSAttenuation", cloudSettings.msAttenuation.value);
            cloudMaterial.SetFloat("_MSContribution", cloudSettings.msContribution.value);
            cloudMaterial.SetFloat("_MSEccentricity", cloudSettings.msEccentricity.value);

            float earthRadius = cloudSettings.earthRadius.value;
            Vector3 camPos = cam.transform.position;
            Vector3 sphereCenter = new Vector3(camPos.x, -earthRadius, camPos.z);
            cloudMaterial.SetVector("_SphereCenter", sphereCenter);
            cloudMaterial.SetFloat("_EarthRadius", earthRadius);

            // --- 视锥体射线计算 ---
            float far = cam.farClipPlane;
            float halfFov = cam.fieldOfView * 0.5f * Mathf.Deg2Rad;
            float aspect = cam.aspect;

            Vector3 up = cam.transform.up * Mathf.Tan(halfFov) * far;
            Vector3 right = cam.transform.right * Mathf.Tan(halfFov) * aspect * far;
            Vector3 forward = cam.transform.forward * far;

            Matrix4x4 frustumCorners = Matrix4x4.identity;
            frustumCorners.SetRow(0, forward - right - up);
            frustumCorners.SetRow(1, forward + right - up);
            frustumCorners.SetRow(2, forward - right + up);
            frustumCorners.SetRow(3, forward + right + up);

            cloudMaterial.SetMatrix("_FrustumCorners", frustumCorners);
            cloudMaterial.SetVector("_CameraPos", camPos);
            cloudMaterial.SetVector("_CameraForward", cam.transform.forward);

            Blitter.BlitCameraTexture(cmd, cameraColorTarget, tempTarget, cloudMaterial, 0);
            Blitter.BlitCameraTexture(cmd, tempTarget, cameraColorTarget);

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public void Dispose()
        {
            tempTarget?.Release();
        }
    }

    CloudRenderPass m_ScriptablePass;
    public Material cloudMaterial;

    public override void Create()
    {
        m_ScriptablePass = new CloudRenderPass();
        m_ScriptablePass.cloudMaterial = cloudMaterial;
        m_ScriptablePass.renderPassEvent = RenderPassEvent.AfterRenderingSkybox;
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (cloudMaterial != null)
        {
            m_ScriptablePass.ConfigureInput(ScriptableRenderPassInput.Color | ScriptableRenderPassInput.Depth);
            renderer.EnqueuePass(m_ScriptablePass);
        }
    }

    protected override void Dispose(bool disposing) { m_ScriptablePass.Dispose(); }
}
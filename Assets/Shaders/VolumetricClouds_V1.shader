Shader "Hidden/VolumetricCloudsAdvanced"
{
    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline" = "UniversalPipeline" }
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            // --- 外部参数 ---
            float4x4 _FrustumCorners;
            float3 _CameraPos;
            float3 _CameraForward;
            
            float4 _CloudMinMax;
            float _CloudDensity;
            TEXTURE2D(_WeatherMap); SAMPLER(sampler_WeatherMap); float _WeatherMapTiling;
            float3 _StratusInfo;
            float3 _CumulusInfo;

            TEXTURE3D(_BaseNoiseTex); SAMPLER(sampler_BaseNoiseTex); float _BaseNoiseScale; float _BaseShapeDetailEffect;
            TEXTURE3D(_DetailNoiseTex); SAMPLER(sampler_DetailNoiseTex); float _DetailNoiseScale; float _DetailEffect;

            float3 _WindDirection;
            float _WindSpeed;

            half4 _ColorBright;
            half4 _ColorDark;
            float _CloudAbsorb;
            float _DarknessThreshold;

            float _ScatterForward; float _ScatterForwardIntensity;
            float _ScatterBackward; float _ScatterBackwardIntensity;

            float _StepSize;
            int _MaxSteps;
            int _LightSteps;

            float3 _SphereCenter;
            float _EarthRadius;

            // --- 核心数学工具库 (来自原贴精华) ---
            float Remap(float v, float minOld, float maxOld, float minNew, float maxNew) {
                return minNew + ((v - minOld) / (maxOld - minOld)) * (maxNew - minNew);
            }

            float GetCloudTypeDensity(float heightFraction, float cloud_min, float cloud_max, float feather) {
                float bottomMask = saturate(Remap(heightFraction, cloud_min, cloud_min + feather * 0.5, 0.0, 1.0));
                float topMask = saturate(Remap(heightFraction, cloud_max - feather, cloud_max, 1.0, 0.0));
                return bottomMask * topMask;
            }

            // Beer-Powder 粉糖效应光照衰减
            float BeerPowder(float density, float absorptivity) {
                return 2.0 * exp(-density * absorptivity) * (1.0 - exp(-2.0 * density));
            }

            // Henyey-Greenstein 双叶散射
            float HenyeyGreenstein(float angle, float g) {
                float g2 = g * g;
                return (1.0 - g2) / (4.0 * PI * pow(abs(1.0 + g2 - 2.0 * g * angle), 1.5));
            }
            float HGScatterMax(float angle, float g_1, float intensity_1, float g_2, float intensity_2) {
                return max(intensity_1 * HenyeyGreenstein(angle, g_1), intensity_2 * HenyeyGreenstein(angle, g_2));
            }

            // --- 球体与云层环带求交 ---
            float2 RaySphereDst(float3 sphereCenter, float sphereRadius, float3 pos, float3 rayDir) {
                float3 oc = pos - sphereCenter;
                float b = dot(rayDir, oc);
                float c = dot(oc, oc) - sphereRadius * sphereRadius;
                float t = b * b - c;
                if(t < 0) return float2(0,0);
                float delta = sqrt(t);
                float dstToSphere = max(-b - delta, 0);
                float dstInSphere = max(-b + delta - dstToSphere, 0);
                return float2(dstToSphere, dstInSphere);
            }

            float2 RayCloudLayerDst(float3 sphereCenter, float earthRadius, float heightMin, float heightMax, float3 pos, float3 rayDir) {
                float2 cloudDstMin = RaySphereDst(sphereCenter, heightMin + earthRadius, pos, rayDir);
                float2 cloudDstMax = RaySphereDst(sphereCenter, heightMax + earthRadius, pos, rayDir);
                
                float dstToCloudLayer = 0;
                float dstInCloudLayer = 0;
                float relativeHeight = length(pos - sphereCenter) - earthRadius;

                if (relativeHeight <= heightMin) {
                    float3 startPos = pos + rayDir * cloudDstMin.y;
                    if (startPos.y >= sphereCenter.y + earthRadius) {
                        dstToCloudLayer = cloudDstMin.y;
                        dstInCloudLayer = cloudDstMax.y - cloudDstMin.y;
                    }
                }
                else if (relativeHeight > heightMin && relativeHeight <= heightMax) {
                    dstToCloudLayer = 0;
                    dstInCloudLayer = cloudDstMin.y > 0 ? cloudDstMin.x : cloudDstMax.y;
                }
                else {
                    dstToCloudLayer = cloudDstMax.x;
                    dstInCloudLayer = cloudDstMin.y > 0 ? cloudDstMin.x - dstToCloudLayer : cloudDstMax.y;
                }
                return float2(dstToCloudLayer, dstInCloudLayer);
            }

            // --- 核心密度采样 ---
            float SampleCloudDensity(float3 pos) {
                float3 windOffset = _WindDirection * _WindSpeed * _Time.y;
                float3 animatedPos = pos + windOffset;

                // 1. 天气图映射
                float2 weatherUV = animatedPos.xz * _WeatherMapTiling;
                float4 weatherData = SAMPLE_TEXTURE2D_LOD(_WeatherMap, sampler_WeatherMap, weatherUV, 0);
                float coverage = saturate(weatherData.r * 2.0 + 0.1) * _CloudDensity; 
                float cloudType = weatherData.r; 
                if (coverage <= 0.0) return 0.0;

                // 2. 高度判定与羽化
                float currentHeight = length(pos - _SphereCenter) - _EarthRadius;
                float heightFraction = saturate((currentHeight - _CloudMinMax.x) / (_CloudMinMax.y - _CloudMinMax.x));

                float stratusDensity = GetCloudTypeDensity(heightFraction, _StratusInfo.x, _StratusInfo.y, _StratusInfo.z);
                float cumulusDensity = GetCloudTypeDensity(heightFraction, _CumulusInfo.x, _CumulusInfo.y, _CumulusInfo.z);
                float cloudTypeDensity = lerp(stratusDensity, cumulusDensity, cloudType);
                if (cloudTypeDensity <= 0.0) return 0.0;

                // 3. 基础 3D 形状
                float3 baseNoiseUV = animatedPos * _BaseNoiseScale;
                float4 baseTex = SAMPLE_TEXTURE3D_LOD(_BaseNoiseTex, sampler_BaseNoiseTex, baseNoiseUV, 0);
                float baseTexFBM = dot(baseTex.gba, float3(0.5, 0.25, 0.125));
    
                // 【核心修复 1：使用减法保留柔和梯度，拒绝菜花硬边！】
                float baseShape = saturate(baseTex.r - (1.0 - baseTexFBM) * _BaseShapeDetailEffect);
                float finalDensity = saturate(baseShape - (1.0 - coverage)) * cloudTypeDensity;
                if (finalDensity <= 0.0) return 0.0;

                // 4. 细节侵蚀 (风速稍快产生翻滚感)
                float3 detailUV = (animatedPos + _WindDirection * _Time.y * 15.0) * _DetailNoiseScale;
                float detailTexFBM = dot(SAMPLE_TEXTURE3D_LOD(_DetailNoiseTex, sampler_DetailNoiseTex, detailUV, 0).rgb, float3(0.5, 0.25, 0.125));
    
                // 乘以一个系数（比如 3.0 或 4.0），放大核心的密度。
                // 这样只要稍微往云内部走一点，erosionModifier 就会迅速降为 0，彻底保护云核不被碎化。
                float erosionModifier = 1.0 - saturate(finalDensity * 4.0);
                finalDensity = saturate(finalDensity - detailTexFBM * _DetailEffect * erosionModifier);
    
                // 基础通透度，如果觉得不够厚，可以上调到 0.6
                return finalDensity * 0.4; 
            }

            half4 Frag(Varyings input) : SV_Target
            {
                float2 uv = input.texcoord;
                half4 originalColor = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv);

                float3 rayDirFar = lerp(
                    lerp(_FrustumCorners[0].xyz, _FrustumCorners[1].xyz, uv.x),
                    lerp(_FrustumCorners[2].xyz, _FrustumCorners[3].xyz, uv.x),
                    uv.y
                );
                float3 rayDir = normalize(rayDirFar);
                float depth = SampleSceneDepth(uv);
                float maxDist = LinearEyeDepth(depth, _ZBufferParams) / dot(_CameraForward, rayDir);

                // 包围盒求交
                float2 boundsInfo = RayCloudLayerDst(_SphereCenter, _EarthRadius, _CloudMinMax.x, _CloudMinMax.y, _CameraPos, rayDir);
                float dstToBox = boundsInfo.x;
                float dstInsideBox = boundsInfo.y;
                
                if(dstInsideBox <= 0 || dstToBox >= maxDist) return originalColor;
                dstInsideBox = min(dstInsideBox, maxDist - dstToBox);
                
                Light mainLight = GetMainLight();
                float3 lightDir = normalize(mainLight.direction);
                float3 lightColor = mainLight.color;
                
                // 双叶相位散射
                float cosAngle = dot(rayDir, lightDir);
                float phase = HGScatterMax(cosAngle, _ScatterForward, _ScatterForwardIntensity, _ScatterBackward, _ScatterBackwardIntensity);
                // 增加基础底光防死黑
                phase = 0.2 + phase * 0.8; 

                // 屏幕空间蓝噪抖动 (Dither)
                float dither = frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
                float stepDist = _StepSize;
                float3 currentPos = _CameraPos + rayDir * (dstToBox + stepDist * dither);
                
                float transmittance = 1.0; 
                float3 totalLum = float3(0,0,0);
                
                for(int i = 0; i < _MaxSteps; i++)
                {
                    if(dstInsideBox <= 0.0 || transmittance <= 0.01) break;
                    
                    float density = SampleCloudDensity(currentPos);
                    if(density > 0.001)
                    {
                        // 光线向太阳步进
                        float lightDensity = 0;
                        float3 lightPos = currentPos;
                        // 强行把向光步进距离缩短！探测距离 = 摄像机步长的 2 到 3 倍即可
                        // 这样能完美捕捉云层表面的透光和明暗交界线
                        float lightStepDist = _StepSize * 2.5;
                        
                        for(int j = 0; j < _LightSteps; j++) {
                            lightPos += lightDir * lightStepDist;
                            lightDensity += max(0, SampleCloudDensity(lightPos) * lightStepDist);
                        }
                        
                        // 光照衰减 (Beer-Powder) 与暗部阈值保护
                        float lightEnergy = BeerPowder(lightDensity, _CloudAbsorb);
                        float currentLum = _DarknessThreshold + (1.0 - _DarknessThreshold) * lightEnergy;
                        
                        // 亮部到暗部的颜色插值
                        float3 cloudColor = lerp(_ColorDark.rgb, _ColorBright.rgb, saturate(currentLum)) * lightColor;
                        
                        // 积分累计
                        float currentDensity = density * stepDist;
                        totalLum += transmittance * cloudColor * currentDensity * phase;
                        transmittance *= exp(-currentDensity * _CloudAbsorb);
                    }

                    currentPos += rayDir * stepDist;
                    dstInsideBox -= stepDist;
                }

                return half4(originalColor.rgb * transmittance + totalLum, 1.0);
            }
            ENDHLSL
        }
    }
}
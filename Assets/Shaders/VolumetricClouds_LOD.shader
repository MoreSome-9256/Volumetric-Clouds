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
            float4 _CloudRange; // X: min, Y: max, Z: thickness, W: 1/thickness
            
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

            // 新增的高级光照接收变量
            float _PhiFwdIntensity;
            float _PhiFwdCompress;
            float _ConeRatio;
            // 🚀 阶段四：多重散射接收变量
            float _MSAttenuation;
            float _MSContribution;
            float _MSEccentricity;

            // 🚀 [蓝噪声修改] 引入蓝噪声贴图变量声明
            TEXTURE2D(_BlueNoiseTex); SAMPLER(sampler_BlueNoiseTex);

            float _StepSize;
            int _MaxSteps;
            int _LightSteps;

            float3 _SphereCenter;
            float _EarthRadius;

            // --- 核心数学工具库 ---
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

            // --- 优化后的密度采样：低成本快速判定门控 ---
            float SampleCloudDensityFast(float3 pos)
            {
                float3 windOffset = _WindDirection * _WindSpeed * _Time.y;
                float3 animatedPos = pos + windOffset;

                // 1. 天气图低成本判定
                float2 weatherUV = animatedPos.xz * _WeatherMapTiling;
                float4 weatherData = SAMPLE_TEXTURE2D_LOD(_WeatherMap, sampler_WeatherMap, weatherUV, 0);
                float coverage = saturate(weatherData.r * 2.0 + 0.1) * _CloudDensity;
                if (coverage <= 0.001) return 0.0;

                // 2. 高度判定
                float currentHeight = length(pos - _SphereCenter) - _EarthRadius;
                if(currentHeight < _CloudMinMax.x || currentHeight > _CloudMinMax.y) return 0.0;
    
                float heightFraction = saturate((currentHeight - _CloudMinMax.x) / (_CloudMinMax.y - _CloudMinMax.x));
                float cloudTypeDensity = lerp(
                    GetCloudTypeDensity(heightFraction, _StratusInfo.x, _StratusInfo.y, _StratusInfo.z),
                    GetCloudTypeDensity(heightFraction, _CumulusInfo.x, _CumulusInfo.y, _CumulusInfo.z),
                    weatherData.r
                );
                if (cloudTypeDensity <= 0.001) return 0.0;

                // 3. 基础 3D 形状噪声
                float3 baseNoiseUV = animatedPos * _BaseNoiseScale;
                float4 baseTex = SAMPLE_TEXTURE3D_LOD(_BaseNoiseTex, sampler_BaseNoiseTex, baseNoiseUV, 0);
                float baseTexFBM = dot(baseTex.gba, float3(0.5, 0.25, 0.125));
                float baseShape = saturate(baseTex.r - (1.0 - baseTexFBM) * _BaseShapeDetailEffect);

                // 1. 先算出带有天气图覆盖率的基础密度
                float baseDensity = saturate(baseShape - (1.0 - coverage));

                // 2. 🚀 关键修改：用高度遮罩对噪声进行侵蚀重映射，而不是简单相乘
                float finalDensity = Remap(baseDensity, 1.0 - cloudTypeDensity, 1.0, 0.0, 1.0);

                return saturate(finalDensity);
            }

            // 🚀 增加 dist 参数用于 LOD 判定
            float SampleCloudDensityDetailed(float3 pos, float baseShapeDensity, float dist)
            {
                if(baseShapeDensity <= 0.0) return 0.0;

                // 🚀 核心优化 1：LOD 细节裁剪。距离超过 15000 米，直接返回基础密度，跳过细节侵蚀
                if(dist > 15000.0) return saturate(baseShapeDensity) * 0.4;

                float3 windOffset = _WindDirection * _WindSpeed * _Time.y;
                float3 animatedPos = pos + windOffset;

                // 4. 细节噪声三维侵蚀
                float3 detailUV = (animatedPos + _WindDirection * _Time.y * 15.0) * _DetailNoiseScale;
                float detailTexFBM = dot(SAMPLE_TEXTURE3D_LOD(_DetailNoiseTex, sampler_DetailNoiseTex, detailUV, 0).rgb, float3(0.5, 0.25, 0.125));

                // 1. 放宽侵蚀保护
                float erosionModifier = 1.0 - saturate(baseShapeDensity * 0.5); 

                // 2. 优化侵蚀算法：使用阈值重映射代替简单的减法
                float finalDensity = Remap(baseShapeDensity, detailTexFBM * _DetailEffect * erosionModifier, 1.0, 0.0, 1.0);

                return saturate(finalDensity) * 0.4;
            }

            // --- 阶段三：物理漫射场 (phi_fwd) 核心常数 ---
            #define HP_PHIFWD_OMEGA0 0.999f 
            #define HP_PHIFWD_KAPPA_OD_SCALE 0.054772f 

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

                float2 boundsInfo = RayCloudLayerDst(_SphereCenter, _EarthRadius, _CloudMinMax.x, _CloudMinMax.y, _CameraPos, rayDir);
                float dstToBox = boundsInfo.x;
                float dstInsideBox = boundsInfo.y;
    
                if(dstInsideBox <= 0 || dstToBox >= maxDist) return originalColor;
    
                float totalDist = min(dstInsideBox, maxDist - dstToBox);
                
                float stepSmall = _StepSize;
                float stepLarge = _StepSize * 2.5; 
                float MAX_TRACE_DIST = _MaxSteps * stepLarge; 
                totalDist = min(totalDist, MAX_TRACE_DIST);
                
                if(totalDist <= 0.0) return originalColor;
    
                Light mainLight = GetMainLight();
                float3 lightDir = normalize(mainLight.direction);
                float3 lightColor = mainLight.color;
    
                float cosAngle = dot(rayDir, lightDir);

                float phaseFunction[3];
                phaseFunction[0] = HGScatterMax(cosAngle, _ScatterForward, _ScatterForwardIntensity, _ScatterBackward, _ScatterBackwardIntensity);
                phaseFunction[1] = HGScatterMax(cosAngle, _ScatterForward * _MSEccentricity, _ScatterForwardIntensity, _ScatterBackward * _MSEccentricity, _ScatterBackwardIntensity);
                phaseFunction[2] = HGScatterMax(cosAngle, _ScatterForward * _MSEccentricity * _MSEccentricity, _ScatterForwardIntensity, _ScatterBackward * _MSEccentricity * _MSEccentricity, _ScatterBackwardIntensity);

                // 🚀 [蓝噪声修改] 替换原本的数学白噪声：frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453)
                // 蓝噪声需要在屏幕空间平铺采样，_ScreenParams.xy 表示屏幕像素宽高
                // 假设你给的蓝噪声贴图是 64x64 的，除以 64.0 来确保它是按照像素进行一一对应映射
                float2 blueNoiseUV = uv * _ScreenParams.xy / 256.0;
                float dither = SAMPLE_TEXTURE2D_LOD(_BlueNoiseTex, sampler_BlueNoiseTex, blueNoiseUV, 0).r;
                
                // 将步进起点的偏移与蓝噪声挂钩，这能极大打乱 Raymarching 的“切片” (Banding) 痕迹
                float dist = dither * stepSmall;
                
                float transmittance = 1.0;
                float3 totalLum = float3(0, 0, 0);

                int iterCount = 0;
                int maxIter = _MaxSteps; 

                [loop]
                while (dist < totalDist && transmittance > 0.01 && iterCount < maxIter)
                {
                    iterCount++;
                    
                    // 🚀 核心优化 2：计算动态 LOD 倍率。
                    // 比如 dist 为 0 时倍率是 1；dist 为 20000 时，倍率变为 3
                    float lodFactor = 1.0 + (dist / 10000.0);
                    
                    // 动态更新当前这一步的步长
                    float currentStepSmall = stepSmall * lodFactor;
                    float currentStepLarge = stepLarge * lodFactor;

                    float3 currentPos = _CameraPos + rayDir * (dstToBox + dist);
                    float baseDensity = SampleCloudDensityFast(currentPos);
        
                    if(baseDensity > 0.001)
                    {
                        // 传入 dist，触发细节裁剪
                        float density = SampleCloudDensityDetailed(currentPos, baseDensity, dist);
            
                        if(density > 0.001)
                        {
                            float lightDensity = 0;
                            float hpHpPhiFwd = 0.0;     
                            float kappaODSum = 0.0;     
                            float T_cum = 1.0;          

                            // 🚀 核心优化 3：远景光照退化。距离越远，向光步进的初始步长越大
                            float curLightStep = currentStepSmall * 0.5; 
                            float cumLightDist = 0.0;
                            float r = _ConeRatio; 
                
                            for(int j = 0; j < _LightSteps; j++) {
                                float3 lightPos = currentPos + lightDir * (cumLightDist + curLightStep * 0.5);
                                
                                float lBase = SampleCloudDensityFast(lightPos);
                                float localSigmaT = lBase * 0.4;
                                float localOD = localSigmaT * curLightStep;
                                
                                lightDensity += max(0, localOD);
                                
                                if (localOD > 0.0001) 
                                {
                                    float kappaStep = localOD * HP_PHIFWD_KAPPA_OD_SCALE;
                                    float kappaToCenter = kappaODSum + kappaStep * 0.5;
                                    float perSrcExp = exp(-kappaToCenter);
                                    
                                    float qSrc = localSigmaT * HP_PHIFWD_OMEGA0 * curLightStep;
                                    float invD = localSigmaT;
                                    
                                    float r_dist = max(cumLightDist + curLightStep * 0.5, curLightStep * 0.5);
                                    float invR = 1.0 / r_dist;
                                    
                                    float msBuild = 1.0 - exp(-(lightDensity * 0.5));
                                    
                                    hpHpPhiFwd += T_cum * qSrc * invD * msBuild * perSrcExp * invR;
                                    
                                    kappaODSum += kappaStep;
                                    T_cum *= exp(-localOD * (1.0 - HP_PHIFWD_OMEGA0));
                                }
                                
                                if(exp(-lightDensity * _CloudAbsorb) < 0.05) break; 
                                
                                cumLightDist += curLightStep;
                                curLightStep *= r; 
                            }
                
                            // --- 光照合成 ---
                            float3 directColorSum = float3(0, 0, 0);
                            
                            for (int o = 0; o < 3; ++o)
                            {
                                float attFactor = pow(_MSAttenuation, (float)o);     
                                float conFactor = pow(_MSContribution, (float)o);    
                                
                                float lightEnergy = BeerPowder(lightDensity * attFactor, _CloudAbsorb);
                                float currentLum = _DarknessThreshold + (1.0 - _DarknessThreshold) * lightEnergy;
                                float3 directColor = lerp(_ColorDark.rgb, _ColorBright.rgb, saturate(currentLum)) * lightColor;
                                
                                directColorSum += directColor * phaseFunction[o] * conFactor; 
                            }

                            float baseEnergy = BeerPowder(lightDensity, _CloudAbsorb);
                            float baseLum = _DarknessThreshold + (1.0 - _DarknessThreshold) * baseEnergy;
                            float3 baseCloudColor = lerp(_ColorDark.rgb, _ColorBright.rgb, saturate(baseLum)) * lightColor;
                            
                            float phiFwdMapped = (1.0 - exp(-hpHpPhiFwd * _PhiFwdCompress)) / max(_PhiFwdCompress, 0.001);
                            float3 phiFwdLum = phiFwdMapped * _ColorDark.rgb * lightColor * _PhiFwdIntensity;
                
                            float3 finalScatterColor = (directColorSum * 0.8) + (baseCloudColor * 0.2) + phiFwdLum;
                
                            // 记得用动态步长去计算当前片段的累积密度
                            float currentDensity = density * currentStepSmall;
                            totalLum += transmittance * finalScatterColor * currentDensity;
                            transmittance *= exp(-currentDensity * _CloudAbsorb);
                        }
                        
                        // 步进距离也用放大后的步伐
                        dist += currentStepSmall;
                    }
                    else
                    {
                        dist += currentStepLarge;
                    }
                }

                return half4(originalColor.rgb * transmittance + totalLum, 1.0);
            }
            ENDHLSL
        }
    }
}
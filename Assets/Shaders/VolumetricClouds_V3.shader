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

            float _StepSize;
            int _MaxSteps;
            int _LightSteps;

            float3 _SphereCenter;
            float _EarthRadius;

            // 🚀 阶段四：多重散射接收变量
            float _MSAttenuation;
            float _MSContribution;
            float _MSEccentricity;

            // --- 核心数学工具库 ---
            float Remap(float v, float minOld, float maxOld, float minNew, float maxNew) {
                return minNew + ((v - minOld) / (maxOld - minOld)) * (maxNew - minNew);
            }
            float RemapClamped(float v, float minOld, float maxOld, float minNew, float maxNew) {
                return saturate(minNew + ((v - minOld) / (maxOld - minOld)) * (maxNew - minNew));
            }
            // 新增带有方向性的粉末效应（只在迎光面边缘生效，赋予银边质感）
            float PowderEffect(float density, float cosAngle) {
                float powder = 1.0 - exp(-density * 2.0);
                return lerp(1.0, powder, smoothstep(0.5, -0.5, cosAngle));
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

            // ---------------- 改写基础形状采样 ----------------
            float SampleCloudDensityFast(float3 pos)
            {
                float3 animatedPos = pos + _WindDirection * _WindSpeed * _Time.y;

                // 1. 天气图判定
                float2 weatherUV = animatedPos.xz * _WeatherMapTiling;
                float4 weatherData = SAMPLE_TEXTURE2D_LOD(_WeatherMap, sampler_WeatherMap, weatherUV, 0);
                float coverage = saturate(weatherData.r * 2.0 + 0.1) * _CloudDensity;
                if (coverage <= 0.001) return 0.0;

                // 2. 相对高度计算 (heightFraction: 0是云底，1是云顶)
                float currentHeight = length(pos - _SphereCenter) - _EarthRadius;
                if(currentHeight < _CloudMinMax.x || currentHeight > _CloudMinMax.y) return 0.0;
                float heightFraction = saturate((currentHeight - _CloudMinMax.x) / (_CloudMinMax.y - _CloudMinMax.x));

                // 【新增】：计算当前采样点到相机的水平距离 (X-Z 平面)
                float distFromCam = length(pos.xz - _CameraPos.xz);
                // 设定一个最大可视距离 (比如 60000 米) 和衰减区间 (比如最后 20000 米开始变淡)
                float maxDist = 30000.0;
                float fadeDist = 20000.0;
                float distanceFade = saturate((maxDist - distFromCam) / fadeDist);
    
                // 如果已经超出最大距离，直接返回 0，节省性能
                if (distanceFade <= 0.0) return 0.0;

                // 3. 基础 3D 形状噪声
                float3 baseNoiseUV = animatedPos * _BaseNoiseScale;
                float4 baseTex = SAMPLE_TEXTURE3D_LOD(_BaseNoiseTex, sampler_BaseNoiseTex, baseNoiseUV, 0);
                float baseTexFBM = dot(baseTex.gba, float3(0.5, 0.25, 0.125));
                float baseShape = RemapClamped(baseTex.r, baseTexFBM * _BaseShapeDetailEffect, 1.0, 0.0, 1.0);

                // ==========================================
                // 🚀 核心形态学塑造 (Shaping): "小-大-小" 的真实轮廓
                // ==========================================

                // A. 底部侵蚀 (Bottom Erosion)：高度 0.0 ~ 0.15 之间
                // 让云在刚生成时向内收缩，越靠近底部收缩得越厉害 (0.5 -> 0.0)
                float bottomErosion = saturate(Remap(heightFraction, 0.0, 0.15, 0.5, 0.0));

                // B. 顶部侵蚀 (Top Erosion)：高度 0.2 ~ 1.0 之间
                // 让云向上逐渐向内收缩，越靠近顶部尖端收缩得越厉害 (0.0 -> 0.8)
                float topErosion = saturate(Remap(heightFraction, 0.2, 1.0, 0.0, 0.8));

                // 合并上下两端的侵蚀力，应用到天气图覆盖率上
                // 这会在 0.15 ~ 0.2 的高度形成一个“最宽”的云腹部
                float heightErosion = bottomErosion + topErosion;
                float shapedCoverage = saturate(coverage - heightErosion);

                // 用处理过后的 Coverage 进行切割，挤出具有真实厚度变化的体积
                float finalDensity = RemapClamped(baseShape, saturate(1.0 - shapedCoverage), 1.0, 0.0, 1.0);

                // C. 边缘软消失 (Fade)：防止云冲破最大/最小高度出现硬切边
                float topFade = smoothstep(1.0, 0.8, heightFraction);
                float bottomFade = smoothstep(0.0, 0.02, heightFraction); // 仅仅做最极限的边缘羽化

                // 最终组合
                return finalDensity * bottomFade * topFade * distanceFade;
            }

            // ---------------- 改写精细侵蚀采样 ----------------
            float SampleCloudDensityDetailed(float3 pos, float baseShapeDensity)
            {
                if(baseShapeDensity <= 0.0) return 0.0;
    
                float3 animatedPos = pos + _WindDirection * _WindSpeed * _Time.y;
                float3 detailUV = (animatedPos + _WindDirection * _Time.y * 15.0) * _DetailNoiseScale;
                float detailTexFBM = dot(SAMPLE_TEXTURE3D_LOD(_DetailNoiseTex, sampler_DetailNoiseTex, detailUV, 0).rgb, float3(0.5, 0.25, 0.125));

                // 【大改重点】核心保护机制：基础密度越大，越不容易被侵蚀，保护云层内部不被掏空
                float erosion = detailTexFBM * _DetailEffect;
                float finalDensity = RemapClamped(baseShapeDensity, erosion * 0.2, 1.0, 0.0, 1.0);

                return finalDensity * 0.4;
            }

            // --- 阶段三：物理漫射场 (phi_fwd) 核心常数 ---
            // 单次散射反照率 (水云极少吸收，极度接近 1)
            #define HP_PHIFWD_OMEGA0 0.999f 
            // 扩散体积衰减系数缩放：sqrt(3 * (1 - ω_0))
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

                // 【修复1：天空盒判定】URP 默认是 Reversed-Z，天空盒的 depth 无限接近于 0
                bool isSkybox = depth < 0.00001; 
                // 如果是天空盒，最大距离设为无限大（比如一千万），否则就是深度图里物体的距离
                float maxDist = isSkybox ? 10000000.0 : (LinearEyeDepth(depth, _ZBufferParams) / dot(_CameraForward, rayDir));

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

                // 🚀 修复 1：恢复纯粹的物理相函数，绝对不能在这里加 0.2（防止光能爆炸）
                float phaseFunction[3];
                phaseFunction[0] = HGScatterMax(cosAngle, _ScatterForward, _ScatterForwardIntensity, _ScatterBackward, _ScatterBackwardIntensity);
                phaseFunction[1] = HGScatterMax(cosAngle, _ScatterForward * _MSEccentricity, _ScatterForwardIntensity, _ScatterBackward * _MSEccentricity, _ScatterBackwardIntensity);
                phaseFunction[2] = HGScatterMax(cosAngle, _ScatterForward * _MSEccentricity * _MSEccentricity, _ScatterForwardIntensity, _ScatterBackward * _MSEccentricity * _MSEccentricity, _ScatterBackwardIntensity);

                float dither = frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
                float dist = dither * stepSmall;
                
                float transmittance = 1.0;
                float3 totalLum = float3(0, 0, 0);

                int iterCount = 0;
                int maxIter = _MaxSteps; 

                [loop]
                while (dist < totalDist && transmittance > 0.01 && iterCount < maxIter)
                {
                    iterCount++;
                    
                    float3 currentPos = _CameraPos + rayDir * (dstToBox + dist);
                    float baseDensity = SampleCloudDensityFast(currentPos);
        
                    if(baseDensity > 0.001)
                    {
                        float density = SampleCloudDensityDetailed(currentPos, baseDensity);
            
                        if(density > 0.001)
                        {
                            float lightDensity = 0;
                            float hpHpPhiFwd = 0.0;     
                            float kappaODSum = 0.0;     
                            float T_cum = 1.0;          

                            float curLightStep = stepSmall * 0.5; 
                            float cumLightDist = 0.0;
                            float r = _ConeRatio; 
                
                            // 简化后的 Light Loop
                            for(int j = 0; j < _LightSteps; j++) {
                                float3 lightPos = currentPos + lightDir * (cumLightDist + curLightStep * 0.5);
                                float lBase = SampleCloudDensityFast(lightPos);
                                // 向太阳方向步进只算密度积累，不做过多发散计算
                                lightDensity += lBase * curLightStep;
    
                                cumLightDist += curLightStep;
                                curLightStep *= _ConeRatio; 
                            }

                            // 提取光照合成（告别魔改加法）
                            float3 directColorSum = float3(0, 0, 0);
                            float powder = PowderEffect(density, cosAngle); 

                            for (int o = 0; o < 3; ++o)
                            {
                                float msFactor = pow(_MSAttenuation, (float)o);
                                // 使用 Beer 定律计算这段距离的光能衰减
                                float transmittanceLight = exp(-lightDensity * _CloudAbsorb * msFactor);
    
                                // 结合粉末效应与多重散射贡献度
                                directColorSum += transmittanceLight * powder * phaseFunction[o] * pow(_MSContribution, (float)o);
                            }

                            // 重新计算当前点的高度比例 (用于环境光插值)
                            float currentHeight = length(currentPos - _SphereCenter) - _EarthRadius;
                            float heightFraction = saturate((currentHeight - _CloudMinMax.x) / (_CloudMinMax.y - _CloudMinMax.x));

                            // 最终在这个步长上产生的内散射光
                            float3 ambientLight = lerp(_ColorDark.rgb, _ColorBright.rgb, heightFraction);
                            float3 finalScatterColor = directColorSum * lightColor + ambientLight * _PhiFwdIntensity;

                            float currentDensity = density * stepSmall;
                            // 积分叠加到画面
                            totalLum += transmittance * finalScatterColor * currentDensity;
                            transmittance *= exp(-currentDensity * _CloudAbsorb);
                        }
                        
                        dist += stepSmall;
                    }
                    else
                    {
                        dist += stepLarge;
                    }
                }

                return half4(originalColor.rgb * transmittance + totalLum, 1.0);
            }
            ENDHLSL
        }
    }
}
using UnityEngine;
using UnityEditor;

public class WorleyNoiseGenerator : EditorWindow
{
    public ComputeShader computeShader;
    public int resolution = 128; // 3D贴图分辨率
    public float frequency = 6.0f; // 噪声团的密集程度

    [MenuItem("Tools/Generate Worley Noise")]
    public static void ShowWindow()
    {
        GetWindow<WorleyNoiseGenerator>("Worley Noise Generator");
    }

    void OnGUI()
    {
        GUILayout.Label("3D Worley Noise Settings", EditorStyles.boldLabel);

        computeShader = (ComputeShader)EditorGUILayout.ObjectField("Compute Shader", computeShader, typeof(ComputeShader), false);
        resolution = EditorGUILayout.IntField("Resolution", resolution);
        frequency = EditorGUILayout.FloatField("Frequency (Cells)", frequency);

        if (GUILayout.Button("Generate 3D Texture") && computeShader != null)
        {
            Generate();
        }
    }

    void Generate()
    {
        // 创建一张支持 GPU 随机写入的 RenderTexture
        RenderTexture rt = new RenderTexture(resolution, resolution, 0, RenderTextureFormat.ARGB32);
        rt.dimension = UnityEngine.Rendering.TextureDimension.Tex3D;
        rt.volumeDepth = resolution;
        rt.enableRandomWrite = true;
        rt.Create();

        // 绑定 Shader 参数并执行
        int kernel = computeShader.FindKernel("CSMain");
        computeShader.SetTexture(kernel, "Result", rt);
        computeShader.SetFloat("_Resolution", resolution);
        computeShader.SetFloat("_Frequency", frequency);

        // 按照 8x8x8 的线程组划分任务
        int threadGroups = Mathf.CeilToInt(resolution / 8.0f);
        computeShader.Dispatch(kernel, threadGroups, threadGroups, threadGroups);

        // 将 GPU 内存中的 RenderTexture 拷贝到可以保存的 Texture3D 资产中
        Texture3D tex3D = new Texture3D(resolution, resolution, resolution, TextureFormat.RGBA32, false);
        Graphics.CopyTexture(rt, tex3D);

        // 存盘
        AssetDatabase.CreateAsset(tex3D, "Assets/WorleyCloud_3D.asset");
        AssetDatabase.SaveAssets();

        rt.Release();
        Debug.Log("高级 Worley 噪声已成功生成于 Assets/WorleyCloud_3D.asset");
    }
}
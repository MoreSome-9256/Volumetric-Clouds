using UnityEngine;
using UnityEditor;
using System.IO;

public class ConvertPNGTo3D : EditorWindow
{
    [MenuItem("Tools/将 PNG 序列合成 3D 纹理")]
    static void GenerateTexture()
    {
        // 1. 弹出对话框选择导出的 PNG 文件夹
        string path = EditorUtility.OpenFolderPanel("选择导出的 PNG 文件夹", "Assets", "");
        if (string.IsNullOrEmpty(path)) return;

        // 2. 获取文件夹内所有的 png 文件
        string[] files = Directory.GetFiles(path, "*.png");
        if (files.Length == 0)
        {
            Debug.LogError("该文件夹内没有找到 PNG 文件！");
            return;
        }
        System.Array.Sort(files); // 确保切片按顺序排列 (0, 1, 2...)

        // 获取单张贴图的尺寸 (假设是立方体，例如 64x64)
        Texture2D tempTex = new Texture2D(2, 2);
        tempTex.LoadImage(File.ReadAllBytes(files[0]));
        int texWidth = tempTex.width;
        int texHeight = tempTex.height;
        int texDepth = files.Length; // PNG 的数量就是 3D 纹理的深度
        DestroyImmediate(tempTex);

        // 3. 创建 3D 纹理
        Texture3D tex3D = new Texture3D(texWidth, texHeight, texDepth, TextureFormat.RGBA32, false);
        tex3D.wrapMode = TextureWrapMode.Repeat;
        tex3D.filterMode = FilterMode.Bilinear;

        Color[] colors = new Color[texWidth * texHeight * texDepth];

        // 4. 读取所有切片像素
        for (int z = 0; z < texDepth; z++)
        {
            Texture2D slice = new Texture2D(2, 2);
            byte[] fileData = File.ReadAllBytes(files[z]);
            slice.LoadImage(fileData);

            Color[] sliceColors = slice.GetPixels();
            for (int y = 0; y < texHeight; y++)
            {
                for (int x = 0; x < texWidth; x++)
                {
                    // 填充到 3D 纹理的一维像素数组中
                    colors[x + y * texWidth + z * texWidth * texHeight] = sliceColors[x + y * texWidth];
                }
            }
            DestroyImmediate(slice);
        }

        // 5. 应用像素并保存为原生的 .asset 文件
        tex3D.SetPixels(colors);
        tex3D.Apply();

        AssetDatabase.CreateAsset(tex3D, "Assets/CloudNoise_Volume_Native.asset");
        AssetDatabase.SaveAssets();

        Debug.Log("🎉 3D 纹理合成成功！已保存在: Assets/CloudNoise_Volume_Native.asset");
    }
}
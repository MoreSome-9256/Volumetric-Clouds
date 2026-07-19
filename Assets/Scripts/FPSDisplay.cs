using UnityEngine;

public class FPSDisplay : MonoBehaviour
{
    [Header("显示设置")]
    public Color textColor = Color.green; // 文字颜色，默认绿色
    public int fontSize = 24;             // 字体大小

    // 用于平滑计算帧率，防止数值跳动太快看不清
    private float deltaTime = 0.0f;

    void Update()
    {
        // 使用 unscaledDeltaTime，确保即使用了 Time.timeScale 慢动作，帧率依然准确
        deltaTime += (Time.unscaledDeltaTime - deltaTime) * 0.1f;
    }

    void OnGUI()
    {
        int w = Screen.width;
        int h = Screen.height;

        // 设置 GUI 样式
        GUIStyle style = new GUIStyle();
        style.alignment = TextAnchor.UpperLeft;
        style.fontSize = fontSize;
        style.fontStyle = FontStyle.Bold;

        // 计算耗时 (毫秒) 和 帧率 (FPS)
        float msec = deltaTime * 1000.0f;
        float fps = 1.0f / deltaTime;

        // 格式化输出字符串
        string text = string.Format("Frame Time: {0:0.1} ms  |  FPS: {1:0.}", msec, fps);

        // 为了防止在白色的云朵或者天空背景下看不清，先画一个黑色的投影
        style.normal.textColor = Color.black;
        GUI.Label(new Rect(11, 11, w, h), text, style);

        // 再画真正的彩色文字
        style.normal.textColor = textColor;
        GUI.Label(new Rect(10, 10, w, h), text, style);
    }
}
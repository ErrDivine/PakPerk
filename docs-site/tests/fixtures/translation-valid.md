# 翻译测试样例

使用版本 1.2，并保持 `PAKPERK_API_BASE_URL` 不变。

## 连接手机

1. 打开[真机指南](../mobile-device-development.md#android-phone-usb-loop)。
2. 运行命令。

   ```bash
   echo "$PAKPERK_API_BASE_URL"

   curl --fail http://localhost:8080/health/ready
   ```

| 检查项 | 预期结果 |
| :--- | ---: |
| API | HTTP 200 |

# Translation fixture

Use version 1.2 and keep `PAKPERK_API_BASE_URL` unchanged.

## Connect the phone

1. Open the [device guide](../mobile-device-development.md#android-phone-usb-loop).
2. Run the command.

   ```bash
   echo "$PAKPERK_API_BASE_URL"

   curl --fail http://localhost:8080/health/ready
   ```

| Check | Expected result |
| :--- | ---: |
| API | HTTP 200 |

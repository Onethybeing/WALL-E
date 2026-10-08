# WALL-E — app

The face: a Flutter app showing two animated eyes that blink, look around,
track your face via the camera, and react with moods (idle/happy/surprised/
thinking). This is the UI layer only — the actual agent logic, tool use, and
voice lives in [`../brain`](../brain).

## Running it

```
flutter pub get
flutter run -d <device>
```

Web preview (useful for iterating on the eyes without a device):

```
flutter build web
cd build/web && python -m http.server 8765
```

Camera-based face tracking is Android/iOS only (no web implementation) and is
automatically skipped when running on web or desktop.

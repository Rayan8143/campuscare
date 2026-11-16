"""CampusCare 2.0 entry point. The v1 single-file app is preserved in legacy/app_v1.py."""
from campuscare import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False)

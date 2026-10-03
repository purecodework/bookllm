from translation_service.app import create_app
from translation_service.config import Settings

# Missing credentials/certificates stop startup; no demonstration login or receipt bypass.
app = create_app(Settings.from_env())

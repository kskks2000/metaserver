# MetaServer

MetaServer는 Flutter 기반 모바일/웹 클라이언트와 FastAPI 백엔드를 사용하는 서비스 플랫폼입니다. 현재는 Firebase Auth 기반 회원 인증, 계정 관리, 투자/거래 화면, KIS/Upbit 연동 기능을 중심으로 구성되어 있습니다.

이 문서는 사람을 위한 프로젝트 안내입니다. AI 에이전트가 따라야 하는 작업 규칙과 배포 지침은 [AGENTS.md](AGENTS.md)를 참고합니다.

## 구성

```text
backend/  FastAPI API, Firebase 인증 검증, DB 연동, 거래/자동매매 API
client/   Flutter Android/Web 클라이언트
docs/     DB 설계 문서와 SQL 마이그레이션
```

## 주요 기술

- Backend: Python, FastAPI, PostgreSQL, Firebase Admin SDK
- Client: Flutter, Firebase Auth, Riverpod, GoRouter, Dio
- Trading: 한국투자증권 KIS, Upbit, Yahoo/시장 데이터 조회

## 로컬 실행

### Backend

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

로컬 개발에서는 환경 설정에 따라 DB 없이 인메모리 사용자 저장소로 기동할 수 있습니다. 실제 DB, Firebase, KIS, Upbit 연동 값은 `.env`에 설정합니다.

### Client

```powershell
cd client
flutter pub get
flutter run -d emulator-5554
```

Android 디버그 빌드는 기본적으로 `http://10.0.2.2:8000/api/v1`을 API 서버로 사용합니다. 배포 빌드와 웹 배포는 운영 도메인의 `/bridge/v1` 경로를 사용합니다.

## 테스트와 빌드

```powershell
cd backend
python -m unittest discover -s tests
```

```powershell
cd client
flutter analyze
flutter test
flutter build web --release
flutter build apk --release
```

## 문서

- [backend/README.md](backend/README.md): 백엔드 상세 실행 및 API 개요
- [client/README.md](client/README.md): 클라이언트/Firebase 설정
- [docs/database-design.md](docs/database-design.md): 전체 DB 설계
- [docs/trading-db-design.md](docs/trading-db-design.md): 거래 도메인 DB 설계

## 배포

웹서버 배포 절차와 접속 정보 사용 규칙은 AI 에이전트용 문서인 [AGENTS.md](AGENTS.md)에 분리되어 있습니다. 운영 배포 전에는 테스트와 빌드 결과를 먼저 확인합니다.

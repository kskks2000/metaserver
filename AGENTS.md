# AGENTS.md

이 문서는 MetaServer 저장소에서 작업하는 AI 에이전트를 위한 지침이다. 사람용 프로젝트 설명은 `README.md`에 둔다.

## 기본 원칙

- 사용자가 요청한 범위 안에서만 수정한다.
- 기존 변경사항이 있을 수 있으므로, 직접 만들지 않은 변경을 되돌리지 않는다.
- 코드 수정 전 관련 파일과 기존 패턴을 먼저 확인한다.
- 수동 편집은 `apply_patch`를 사용한다.
- 검색은 우선 `rg` 또는 `rg --files`를 사용한다.
- 테스트가 가능한 변경은 가능한 범위에서 직접 검증한다.
- 최종 응답에는 수정 내용, 검증 결과, 배포 여부를 간결하게 보고한다.

## 프로젝트 구조

```text
backend/  FastAPI 백엔드
client/   Flutter Android/Web 클라이언트
docs/     설계 문서와 DB 마이그레이션
```

## 자주 쓰는 검증 명령

Backend:

```powershell
cd backend
python -m unittest discover -s tests
```

Client:

```powershell
cd client
flutter analyze
flutter test
flutter build web --release
flutter build apk --release
```

환경 제약으로 `flutter pub get`이 Windows Developer Mode/symlink 문제를 만나면, 원인을 명시하고 가능한 경우 `--no-pub` 검증으로 이어간다.

## 웹서버 배포

웹서버 배포는 sFTP 방식으로 진행한다. 웹서버 접속 정보는 프로젝트 루트의 `.env` 파일을 참고한다.

배포 기준 도메인은 항상 `https://www.metaserver.co.kr`이다. 사용자가 별도로 다른 도메인을 말하더라도, 웹서버 배포 완료 검증은 반드시 `https://www.metaserver.co.kr`에서 수행한다.

필요 환경 변수:

- `WEB_SFTP_HOST`
- `WEB_SFTP_USER`
- `WEB_SFTP_PASSWORD`

배포 시 원칙:

- 비밀번호나 운영 접속 정보를 코드, 문서, 로그에 새로 하드코딩하지 않는다.
- `.env`에서 위 환경 변수를 읽어 sFTP 접속에 사용한다.
- 웹 프론트 변경은 `client/build/web` 산출물을 패키징해 `/web`에 반영한다.
- 백엔드 변경은 필요한 백엔드 파일을 패키징해 `/web/backend`에 반영하고 API 프로세스를 재시작한다.
- 배포 전에는 가능한 테스트와 빌드를 먼저 수행한다.
- 배포 후에는 반드시 `https://www.metaserver.co.kr`에서 화면 또는 관련 API 동작을 테스트한다.
- 완료 보고는 `https://www.metaserver.co.kr` 테스트가 끝난 뒤에만 한다.
- 최종 응답에는 `https://www.metaserver.co.kr`에서 무엇을 확인했는지 명시한다.

웹서버 배포 요청이 있으면 항상 이 섹션을 따른다.

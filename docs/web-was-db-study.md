# Web / WAS / DB 핵심 정리 (ESTgames 면접 대비)

## 면접에서 물어볼 수 있는 것

### "Web서버와 WAS 차이가 뭔가요?"
> Web서버(Nginx/Apache)는 정적 콘텐츠(HTML, CSS, JS, 이미지)를 클라이언트에게 직접 전달합니다.
> WAS(Tomcat, uWSGI, Gunicorn)는 동적 콘텐츠를 생성하는 애플리케이션 로직을 실행합니다.
> 일반적 구성: 클라이언트 → Nginx(리버스 프록시 + 정적 파일) → Tomcat/Gunicorn(비즈니스 로직) → DB
> 
> 게임에서는: 클라이언트(게임 클라이언트) → LB → 게임 서버(WAS 역할) → DB + 캐시(Redis)
> 대규모 동시접속 처리를 위해 WAS를 수평 확장(scale-out)하고 LB로 분산합니다.

### "DB 관련 경험은?"
> 직접 DBA 경험은 없지만:
> - Aurora Serverless v2 (PostgreSQL)를 아키텍처에 설계한 경험 (포트폴리오)
> - m365-toolkit에서 structured JSON 로그 설계 (데이터 모델링 감각)
> - AWS SAA 자격증에서 RDS, DynamoDB, ElastiCache 아키텍처 학습
> - SQL 기초 (SELECT, JOIN, INDEX 개념)

### "게임 서비스에서 DB 병목이 생기면?"
> 1. 읽기 부하: Read Replica 추가 (Aurora는 최대 15개)
> 2. 캐시: Redis/Memcached 앞단에 배치 (hot data)
> 3. 쿼리 최적화: EXPLAIN으로 실행계획 확인, 인덱스 추가
> 4. 수직 확장: 인스턴스 사이즈 업 (단기 해결)
> 5. 샤딩: 게임 서버별 DB 분리 (장기 해결)

### "Nginx 리버스 프록시 설정해본 적 있나요?"
> 직접 프로덕션 설정은 없지만, 구조를 이해하고 있습니다:
> ```nginx
> upstream app_servers {
>     server 10.0.1.10:8080;
>     server 10.0.1.11:8080;
> }
> server {
>     listen 80;
>     location / {
>         proxy_pass http://app_servers;
>     }
>     location /static/ {
>         root /var/www/html;
>     }
> }
> ```
> Wezle ICT에서 VMware 위에 DNS, DHCP, WEB 서버를 구축한 경험이 있고,
> Gluten-Free Korea 사이트를 Cloudflare에 배포/운영하고 있어서
> 웹 인프라의 전체 흐름을 이해합니다.

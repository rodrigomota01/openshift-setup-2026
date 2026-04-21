# Aplicacao Robusta + Grafana para Logs da Equipe de Dev

Guia para deploy de uma aplicacao robusta com multiplos componentes e configuracao do Grafana com dashboards de logs para a equipe de desenvolvimento.

**Pre-requisitos:** Stack de logging ja configurada (Loki + Cluster Logging + Grafana) conforme o guia `pos-upgrade-ocp-4.18.md`.

---

## 1. Aplicacao Robusta - Microservicos

Uma aplicacao com 4 componentes que simula um cenario real de producao:

| Componente | Funcao | Tecnologia |
|-----------|--------|------------|
| **frontend** | Interface web + proxy reverso | Nginx + HTML/JS |
| **api** | REST API com logica de negocio | Python (Flask) |
| **worker** | Processamento assincrono de tarefas | Python |
| **database** | Armazenamento de dados | PostgreSQL |

### 1.1 Criar o Projeto

```bash
oc new-project demo-microservices
```

### 1.2 Deploy do PostgreSQL

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: demo-microservices
type: Opaque
stringData:
  POSTGRES_DB: "appdb"
  POSTGRES_USER: "appuser"
  POSTGRES_PASSWORD: "S3cur3P@ssw0rd"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: database
  namespace: demo-microservices
  labels:
    app: demo-microservices
    component: database
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-microservices
      component: database
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: demo-microservices
        component: database
    spec:
      containers:
        - name: postgres
          image: registry.redhat.io/rhel9/postgresql-16:latest
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRESQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_DB
            - name: POSTGRESQL_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_USER
            - name: POSTGRESQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_PASSWORD
          volumeMounts:
            - name: data
              mountPath: /var/lib/pgsql/data
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U $POSTGRESQL_USER -d $POSTGRESQL_DATABASE
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U $POSTGRESQL_USER -d $POSTGRESQL_DATABASE
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: demo-microservices
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: lvms-vg1
---
apiVersion: v1
kind: Service
metadata:
  name: database
  namespace: demo-microservices
spec:
  selector:
    app: demo-microservices
    component: database
  ports:
    - port: 5432
      targetPort: 5432
EOF
```

### 1.3 Deploy da API (Python Flask)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-code
  namespace: demo-microservices
data:
  app.py: |
    import os
    import json
    import time
    import random
    import logging
    import traceback
    import uuid
    from datetime import datetime
    from functools import wraps

    from flask import Flask, request, jsonify, g
    import psycopg2
    from psycopg2.extras import RealDictCursor

    # ============================================================
    # Logging estruturado em JSON
    # ============================================================
    class JSONFormatter(logging.Formatter):
        def format(self, record):
            log_entry = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "level": record.levelname.lower(),
                "logger": record.name,
                "message": record.getMessage(),
                "module": record.module,
                "function": record.funcName,
                "line": record.lineno,
            }
            if hasattr(record, "request_id"):
                log_entry["request_id"] = record.request_id
            if hasattr(record, "method"):
                log_entry["method"] = record.method
            if hasattr(record, "path"):
                log_entry["path"] = record.path
            if hasattr(record, "status_code"):
                log_entry["status_code"] = record.status_code
            if hasattr(record, "duration_ms"):
                log_entry["duration_ms"] = record.duration_ms
            if hasattr(record, "user_id"):
                log_entry["user_id"] = record.user_id
            if record.exc_info and record.exc_info[0]:
                log_entry["exception"] = {
                    "type": record.exc_info[0].__name__,
                    "message": str(record.exc_info[1]),
                    "traceback": traceback.format_exception(*record.exc_info),
                }
            return json.dumps(log_entry)

    handler = logging.StreamHandler()
    handler.setFormatter(JSONFormatter())
    logging.root.handlers = [handler]
    logging.root.setLevel(logging.INFO)

    logger = logging.getLogger("api")

    # ============================================================
    # Flask App
    # ============================================================
    app = Flask(__name__)

    DB_CONFIG = {
        "host": os.getenv("DB_HOST", "database"),
        "port": int(os.getenv("DB_PORT", "5432")),
        "dbname": os.getenv("DB_NAME", "appdb"),
        "user": os.getenv("DB_USER", "appuser"),
        "password": os.getenv("DB_PASSWORD", "S3cur3P@ssw0rd"),
    }

    def get_db():
        if "db" not in g:
            try:
                g.db = psycopg2.connect(**DB_CONFIG, cursor_factory=RealDictCursor)
                g.db.autocommit = True
            except psycopg2.OperationalError as e:
                logger.error("Falha ao conectar ao banco de dados", exc_info=True)
                raise
        return g.db

    @app.teardown_appcontext
    def close_db(exception):
        db = g.pop("db", None)
        if db is not None:
            db.close()

    def init_db():
        """Cria as tabelas no startup."""
        for attempt in range(10):
            try:
                conn = psycopg2.connect(**DB_CONFIG)
                conn.autocommit = True
                cur = conn.cursor()
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS orders (
                        id SERIAL PRIMARY KEY,
                        order_id VARCHAR(36) UNIQUE NOT NULL,
                        customer_name VARCHAR(255) NOT NULL,
                        product VARCHAR(255) NOT NULL,
                        quantity INTEGER NOT NULL,
                        status VARCHAR(50) DEFAULT 'pending',
                        created_at TIMESTAMP DEFAULT NOW(),
                        updated_at TIMESTAMP DEFAULT NOW()
                    );
                    CREATE TABLE IF NOT EXISTS tasks (
                        id SERIAL PRIMARY KEY,
                        task_id VARCHAR(36) UNIQUE NOT NULL,
                        type VARCHAR(100) NOT NULL,
                        payload JSONB,
                        status VARCHAR(50) DEFAULT 'queued',
                        result JSONB,
                        created_at TIMESTAMP DEFAULT NOW(),
                        processed_at TIMESTAMP
                    );
                """)
                cur.close()
                conn.close()
                logger.info("Banco de dados inicializado com sucesso")
                return
            except psycopg2.OperationalError:
                logger.warning(f"Tentativa {attempt+1}/10 - banco nao disponivel, aguardando...")
                time.sleep(3)
        logger.critical("Falha ao inicializar banco de dados apos 10 tentativas")

    # ============================================================
    # Middleware de logging
    # ============================================================
    @app.before_request
    def before_request():
        g.request_id = request.headers.get("X-Request-ID", str(uuid.uuid4())[:8])
        g.start_time = time.time()

    @app.after_request
    def after_request(response):
        duration_ms = round((time.time() - g.start_time) * 1000, 2)
        extra = {
            "request_id": g.request_id,
            "method": request.method,
            "path": request.path,
            "status_code": response.status_code,
            "duration_ms": duration_ms,
        }
        log = logging.LogRecord(
            name="api.request",
            level=logging.INFO if response.status_code < 400 else logging.WARNING,
            pathname="",
            lineno=0,
            msg=f"{request.method} {request.path} -> {response.status_code} ({duration_ms}ms)",
            args=(),
            exc_info=None,
        )
        for k, v in extra.items():
            setattr(log, k, v)
        logger.handle(log)
        response.headers["X-Request-ID"] = g.request_id
        return response

    # ============================================================
    # Endpoints
    # ============================================================
    @app.route("/health")
    def health():
        try:
            db = get_db()
            cur = db.cursor()
            cur.execute("SELECT 1")
            cur.close()
            return jsonify({"status": "healthy", "database": "connected"})
        except Exception:
            logger.error("Health check falhou - banco indisponivel", exc_info=True)
            return jsonify({"status": "unhealthy", "database": "disconnected"}), 503

    @app.route("/ready")
    def ready():
        return jsonify({"status": "ready"})

    @app.route("/api/orders", methods=["GET"])
    def list_orders():
        try:
            db = get_db()
            cur = db.cursor()
            cur.execute("SELECT * FROM orders ORDER BY created_at DESC LIMIT 50")
            orders = cur.fetchall()
            cur.close()
            logger.info(f"Listando {len(orders)} pedidos")
            return jsonify({"orders": [dict(o) for o in orders], "count": len(orders)}, default=str)
        except Exception:
            logger.error("Erro ao listar pedidos", exc_info=True)
            return jsonify({"error": "Falha ao buscar pedidos"}), 500

    @app.route("/api/orders", methods=["POST"])
    def create_order():
        data = request.get_json(silent=True) or {}
        customer = data.get("customer_name", f"Customer-{random.randint(1,999)}")
        product = data.get("product", random.choice(["Notebook", "Monitor", "Teclado", "Mouse", "Headset"]))
        quantity = data.get("quantity", random.randint(1, 10))
        order_id = str(uuid.uuid4())

        # Simular falha intermitente (5% de chance)
        if random.random() < 0.05:
            logger.error(f"Falha ao processar pedido - servico de pagamento indisponivel", extra={"request_id": g.request_id})
            return jsonify({"error": "Servico de pagamento temporariamente indisponivel"}), 503

        try:
            db = get_db()
            cur = db.cursor()
            cur.execute(
                "INSERT INTO orders (order_id, customer_name, product, quantity) VALUES (%s, %s, %s, %s) RETURNING *",
                (order_id, customer, product, quantity),
            )
            order = dict(cur.fetchone())
            cur.close()

            # Criar task para processamento async
            task_id = str(uuid.uuid4())
            cur = db.cursor()
            cur.execute(
                "INSERT INTO tasks (task_id, type, payload, status) VALUES (%s, %s, %s, %s)",
                (task_id, "process_order", json.dumps({"order_id": order_id}), "queued"),
            )
            cur.close()

            logger.info(f"Pedido criado: {order_id} - {product} x{quantity} para {customer}", extra={"request_id": g.request_id, "user_id": customer})
            return jsonify({"order": order, "task_id": task_id}, default=str), 201
        except Exception:
            logger.error("Erro ao criar pedido", exc_info=True)
            return jsonify({"error": "Falha ao criar pedido"}), 500

    @app.route("/api/orders/<order_id>", methods=["GET"])
    def get_order(order_id):
        try:
            db = get_db()
            cur = db.cursor()
            cur.execute("SELECT * FROM orders WHERE order_id = %s", (order_id,))
            order = cur.fetchone()
            cur.close()
            if not order:
                logger.warning(f"Pedido nao encontrado: {order_id}")
                return jsonify({"error": "Pedido nao encontrado"}), 404
            return jsonify({"order": dict(order)}, default=str)
        except Exception:
            logger.error(f"Erro ao buscar pedido {order_id}", exc_info=True)
            return jsonify({"error": "Falha ao buscar pedido"}), 500

    @app.route("/api/tasks", methods=["GET"])
    def list_tasks():
        try:
            db = get_db()
            cur = db.cursor()
            cur.execute("SELECT * FROM tasks ORDER BY created_at DESC LIMIT 50")
            tasks = cur.fetchall()
            cur.close()
            return jsonify({"tasks": [dict(t) for t in tasks], "count": len(tasks)}, default=str)
        except Exception:
            logger.error("Erro ao listar tasks", exc_info=True)
            return jsonify({"error": "Falha ao listar tasks"}), 500

    @app.route("/api/simulate/error", methods=["POST"])
    def simulate_error():
        """Endpoint para simular erros - util para testar alertas."""
        error_type = request.args.get("type", "generic")
        if error_type == "exception":
            try:
                result = 1 / 0
            except Exception:
                logger.error("Excecao simulada - divisao por zero", exc_info=True)
                return jsonify({"error": "Excecao simulada"}), 500
        elif error_type == "timeout":
            logger.warning("Simulando timeout de 10s no servico externo")
            time.sleep(min(int(request.args.get("seconds", 2)), 10))
            logger.error("Timeout no servico externo apos espera")
            return jsonify({"error": "Timeout simulado"}), 504
        elif error_type == "db":
            logger.critical("Simulando falha critica de banco de dados - conexao recusada")
            return jsonify({"error": "Database connection refused"}), 500
        elif error_type == "burst":
            count = min(int(request.args.get("count", 20)), 100)
            for i in range(count):
                logger.error(f"ERROR BURST [{i+1}/{count}] - falha massiva simulada no servico de pedidos")
            return jsonify({"message": f"{count} erros gerados"}), 200
        else:
            logger.error(f"Erro generico simulado via endpoint /simulate/error")
            return jsonify({"error": "Erro generico simulado"}), 500

    @app.route("/api/info")
    def info():
        return jsonify({
            "app": "demo-microservices-api",
            "version": "1.0.0",
            "hostname": os.getenv("HOSTNAME", "unknown"),
            "endpoints": [
                "GET  /health",
                "GET  /ready",
                "GET  /api/orders",
                "POST /api/orders",
                "GET  /api/orders/<id>",
                "GET  /api/tasks",
                "POST /api/simulate/error?type=exception|timeout|db|burst",
                "GET  /api/info",
            ],
        })

    if __name__ == "__main__":
        init_db()
        logger.info("API iniciada na porta 8080")
        app.run(host="0.0.0.0", port=8080)

  requirements.txt: |
    flask==3.1.1
    psycopg2-binary==2.9.10
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: demo-microservices
  labels:
    app: demo-microservices
    component: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-microservices
      component: api
  template:
    metadata:
      labels:
        app: demo-microservices
        component: api
    spec:
      containers:
        - name: api
          image: registry.access.redhat.com/ubi9/python-311:latest
          command:
            - /bin/bash
            - -c
            - |
              pip install --quiet -r /app/requirements.txt && python /app/app.py
          env:
            - name: DB_HOST
              value: "database"
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_DB
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_PASSWORD
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
          volumeMounts:
            - name: app-code
              mountPath: /app
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: app-code
          configMap:
            name: api-code
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: demo-microservices
spec:
  selector:
    app: demo-microservices
    component: api
  ports:
    - port: 8080
      targetPort: 8080
EOF
```

### 1.4 Deploy do Worker (Processamento Assincrono)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: worker-code
  namespace: demo-microservices
data:
  worker.py: |
    import os
    import json
    import time
    import random
    import logging
    from datetime import datetime

    import psycopg2
    from psycopg2.extras import RealDictCursor

    # ============================================================
    # Logging estruturado
    # ============================================================
    class JSONFormatter(logging.Formatter):
        def format(self, record):
            log_entry = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "level": record.levelname.lower(),
                "logger": record.name,
                "message": record.getMessage(),
                "component": "worker",
            }
            if hasattr(record, "task_id"):
                log_entry["task_id"] = record.task_id
            if hasattr(record, "task_type"):
                log_entry["task_type"] = record.task_type
            if hasattr(record, "duration_ms"):
                log_entry["duration_ms"] = record.duration_ms
            if record.exc_info and record.exc_info[0]:
                log_entry["exception"] = str(record.exc_info[1])
            return json.dumps(log_entry)

    handler = logging.StreamHandler()
    handler.setFormatter(JSONFormatter())
    logging.root.handlers = [handler]
    logging.root.setLevel(logging.INFO)

    logger = logging.getLogger("worker")

    DB_CONFIG = {
        "host": os.getenv("DB_HOST", "database"),
        "port": int(os.getenv("DB_PORT", "5432")),
        "dbname": os.getenv("DB_NAME", "appdb"),
        "user": os.getenv("DB_USER", "appuser"),
        "password": os.getenv("DB_PASSWORD", "S3cur3P@ssw0rd"),
    }

    def get_connection():
        return psycopg2.connect(**DB_CONFIG, cursor_factory=RealDictCursor)

    def process_order(task, conn):
        """Simula processamento de pedido."""
        payload = task["payload"] if isinstance(task["payload"], dict) else json.loads(task["payload"])
        order_id = payload.get("order_id")
        logger.info(f"Processando pedido {order_id}", extra={"task_id": task["task_id"], "task_type": "process_order"})

        # Simular processamento com duracao variavel
        processing_time = random.uniform(0.5, 3.0)
        time.sleep(processing_time)

        # Simular falha em 10% dos casos
        if random.random() < 0.10:
            logger.error(
                f"Falha ao processar pedido {order_id} - servico de estoque indisponivel",
                extra={"task_id": task["task_id"], "task_type": "process_order", "duration_ms": round(processing_time * 1000, 2)},
            )
            return "failed", {"error": "Estoque indisponivel"}

        # Atualizar status do pedido
        cur = conn.cursor()
        cur.execute(
            "UPDATE orders SET status = 'processed', updated_at = NOW() WHERE order_id = %s",
            (order_id,),
        )
        cur.close()
        conn.commit()

        logger.info(
            f"Pedido {order_id} processado com sucesso em {round(processing_time*1000)}ms",
            extra={"task_id": task["task_id"], "task_type": "process_order", "duration_ms": round(processing_time * 1000, 2)},
        )
        return "completed", {"order_id": order_id, "processing_time_ms": round(processing_time * 1000, 2)}

    TASK_HANDLERS = {
        "process_order": process_order,
    }

    def poll_tasks():
        """Loop principal do worker - busca e processa tasks."""
        logger.info(f"Worker iniciado - hostname: {os.getenv('HOSTNAME', 'unknown')}")
        consecutive_empty = 0

        while True:
            try:
                conn = get_connection()
                cur = conn.cursor()

                # Pegar proxima task da fila (com lock)
                cur.execute("""
                    UPDATE tasks SET status = 'processing'
                    WHERE id = (
                        SELECT id FROM tasks
                        WHERE status = 'queued'
                        ORDER BY created_at ASC
                        LIMIT 1
                        FOR UPDATE SKIP LOCKED
                    )
                    RETURNING *
                """)
                task = cur.fetchone()
                conn.commit()

                if not task:
                    consecutive_empty += 1
                    if consecutive_empty % 30 == 0:
                        logger.info(f"Nenhuma task na fila (idle ha {consecutive_empty * 2}s)")
                    cur.close()
                    conn.close()
                    time.sleep(2)
                    continue

                consecutive_empty = 0
                task = dict(task)
                task_type = task["type"]

                handler = TASK_HANDLERS.get(task_type)
                if not handler:
                    logger.warning(f"Tipo de task desconhecido: {task_type}", extra={"task_id": task["task_id"]})
                    cur.execute(
                        "UPDATE tasks SET status = 'failed', result = %s, processed_at = NOW() WHERE task_id = %s",
                        (json.dumps({"error": f"Handler nao encontrado para tipo: {task_type}"}), task["task_id"]),
                    )
                    conn.commit()
                    cur.close()
                    conn.close()
                    continue

                start = time.time()
                status, result = handler(task, conn)
                duration = round((time.time() - start) * 1000, 2)

                cur = conn.cursor()
                cur.execute(
                    "UPDATE tasks SET status = %s, result = %s, processed_at = NOW() WHERE task_id = %s",
                    (status, json.dumps(result), task["task_id"]),
                )
                conn.commit()
                cur.close()
                conn.close()

            except psycopg2.OperationalError:
                logger.error("Conexao com banco perdida - tentando reconectar em 5s", exc_info=True)
                time.sleep(5)
            except Exception:
                logger.error("Erro inesperado no worker", exc_info=True)
                time.sleep(2)

    if __name__ == "__main__":
        # Aguardar banco ficar disponivel
        for attempt in range(20):
            try:
                conn = get_connection()
                conn.close()
                break
            except psycopg2.OperationalError:
                logger.warning(f"Aguardando banco... tentativa {attempt+1}/20")
                time.sleep(3)

        poll_tasks()

  requirements.txt: |
    psycopg2-binary==2.9.10
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: demo-microservices
  labels:
    app: demo-microservices
    component: worker
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-microservices
      component: worker
  template:
    metadata:
      labels:
        app: demo-microservices
        component: worker
    spec:
      containers:
        - name: worker
          image: registry.access.redhat.com/ubi9/python-311:latest
          command:
            - /bin/bash
            - -c
            - |
              pip install --quiet -r /app/requirements.txt && python /app/worker.py
          env:
            - name: DB_HOST
              value: "database"
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_DB
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_PASSWORD
          volumeMounts:
            - name: app-code
              mountPath: /app
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 300m
              memory: 256Mi
      volumes:
        - name: app-code
          configMap:
            name: worker-code
EOF
```

### 1.5 Deploy do Frontend (Nginx)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: frontend-config
  namespace: demo-microservices
data:
  nginx.conf: |
    worker_processes auto;
    error_log /dev/stderr warn;
    pid /tmp/nginx.pid;

    events {
        worker_connections 1024;
    }

    http {
        include /etc/nginx/mime.types;
        default_type application/octet-stream;

        log_format json_combined escape=json
          '{'
            '"timestamp":"$time_iso8601",'
            '"level":"info",'
            '"logger":"nginx",'
            '"method":"$request_method",'
            '"path":"$uri",'
            '"status_code":$status,'
            '"duration_ms":$request_time,'
            '"remote_addr":"$remote_addr",'
            '"user_agent":"$http_user_agent",'
            '"bytes_sent":$bytes_sent,'
            '"upstream_response_time":"$upstream_response_time"'
          '}';

        access_log /dev/stdout json_combined;

        sendfile on;
        keepalive_timeout 65;
        client_body_temp_path /tmp/nginx-client-body;
        proxy_temp_path /tmp/nginx-proxy;
        fastcgi_temp_path /tmp/nginx-fastcgi;
        uwsgi_temp_path /tmp/nginx-uwsgi;
        scgi_temp_path /tmp/nginx-scgi;

        server {
            listen 8080;

            location / {
                root /opt/app-root/src;
                index index.html;
            }

            location /api/ {
                proxy_pass http://api:8080;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Request-ID $request_id;
            }
        }
    }

  index.html: |
    <!DOCTYPE html>
    <html lang="pt-BR">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Demo Microservices - OCP</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #1a1a2e; color: #eee; padding: 20px; }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { color: #e94560; margin-bottom: 20px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 20px; margin-bottom: 20px; }
        .card { background: #16213e; border-radius: 12px; padding: 20px; border: 1px solid #0f3460; }
        .card h2 { color: #e94560; margin-bottom: 15px; font-size: 1.1em; }
        button { background: #e94560; color: white; border: none; padding: 10px 20px; border-radius: 6px; cursor: pointer; margin: 5px; font-size: 14px; }
        button:hover { background: #c73e54; }
        button.warning { background: #f5a623; }
        button.danger { background: #d63031; }
        .output { background: #0a0a1a; border-radius: 8px; padding: 15px; margin-top: 10px; font-family: 'Courier New', monospace; font-size: 13px; max-height: 300px; overflow-y: auto; white-space: pre-wrap; }
        .status { display: inline-block; padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: bold; }
        .status.ok { background: #00b894; }
        .status.error { background: #d63031; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid #0f3460; font-size: 13px; }
        th { color: #e94560; }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>Demo Microservices - OpenShift</h1>
        <p style="margin-bottom:20px; color:#888;">Aplicacao de demonstracao para validar stack de logging (Loki + Grafana)</p>

        <div class="grid">
          <div class="card">
            <h2>Health Check</h2>
            <button onclick="checkHealth()">Verificar Saude</button>
            <div id="health-output" class="output">Clique para verificar...</div>
          </div>

          <div class="card">
            <h2>Pedidos</h2>
            <button onclick="createOrder()">Criar Pedido</button>
            <button onclick="createOrders(10)">Criar 10 Pedidos</button>
            <button onclick="listOrders()">Listar Pedidos</button>
            <div id="orders-output" class="output">Clique para interagir...</div>
          </div>

          <div class="card">
            <h2>Tasks (Worker)</h2>
            <button onclick="listTasks()">Listar Tasks</button>
            <div id="tasks-output" class="output">Clique para ver tasks...</div>
          </div>

          <div class="card">
            <h2>Simulacao de Erros (para testar alertas)</h2>
            <button class="warning" onclick="simulateError('exception')">Excecao</button>
            <button class="warning" onclick="simulateError('timeout')">Timeout</button>
            <button class="danger" onclick="simulateError('db')">DB Crash</button>
            <button class="danger" onclick="simulateError('burst&count=30')">Burst 30 Erros</button>
            <div id="errors-output" class="output">Use os botoes para simular falhas...</div>
          </div>
        </div>

        <div class="card">
          <h2>Endpoints Disponiveis</h2>
          <div id="info-output" class="output">Carregando...</div>
        </div>
      </div>

      <script>
        async function api(path, opts = {}) {
          try {
            const res = await fetch('/api' + path, opts);
            return { status: res.status, data: await res.json() };
          } catch (e) {
            return { status: 0, data: { error: e.message } };
          }
        }

        function show(id, data) {
          document.getElementById(id).textContent = JSON.stringify(data, null, 2);
        }

        async function checkHealth() {
          const r = await api('/health');
          show('health-output', r.data);
        }

        async function createOrder() {
          const r = await api('/orders', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
          show('orders-output', r.data);
        }

        async function createOrders(n) {
          show('orders-output', 'Criando ' + n + ' pedidos...');
          const results = [];
          for (let i = 0; i < n; i++) {
            const r = await api('/orders', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
            results.push({ order: r.data.order?.order_id?.substr(0,8), status: r.status });
          }
          show('orders-output', results);
        }

        async function listOrders() {
          const r = await api('/orders');
          show('orders-output', r.data);
        }

        async function listTasks() {
          const r = await api('/tasks');
          show('tasks-output', r.data);
        }

        async function simulateError(type) {
          const r = await api('/simulate/error?type=' + type, { method: 'POST' });
          show('errors-output', { type, status: r.status, response: r.data });
        }

        // Carregar info na inicializacao
        api('/info').then(r => show('info-output', r.data));
      </script>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: demo-microservices
  labels:
    app: demo-microservices
    component: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-microservices
      component: frontend
  template:
    metadata:
      labels:
        app: demo-microservices
        component: frontend
    spec:
      containers:
        - name: nginx
          image: registry.access.redhat.com/ubi9/nginx-124:latest
          command:
            - nginx
            - -c
            - /etc/nginx-custom/nginx.conf
            - -g
            - "daemon off;"
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx-custom
            - name: html
              mountPath: /opt/app-root/src
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 10
      volumes:
        - name: nginx-config
          configMap:
            name: frontend-config
            items:
              - key: nginx.conf
                path: nginx.conf
        - name: html
          configMap:
            name: frontend-config
            items:
              - key: index.html
                path: index.html
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: demo-microservices
spec:
  selector:
    app: demo-microservices
    component: frontend
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: demo-microservices
  namespace: demo-microservices
spec:
  to:
    kind: Service
    name: frontend
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
```

### 1.6 Criar Alertas para a Aplicacao

```bash
cat <<'EOF' | oc apply -f -
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  name: microservices-log-alerts
  namespace: demo-microservices
  labels:
    openshift.io/cluster-monitoring: "true"
spec:
  tenantID: application
  groups:
    - name: microservices-logs
      interval: 1m
      rules:
        - alert: APIHighErrorRate
          expr: |
            sum(count_over_time({kubernetes_namespace_name="demo-microservices", kubernetes_container_name="api"} |= "error" [5m])) > 15
          for: 2m
          labels:
            severity: warning
            app: demo-microservices
            component: api
          annotations:
            summary: "Alta taxa de erros na API"
            description: "Mais de 15 logs de erro na API nos ultimos 5 minutos."

        - alert: WorkerTaskFailures
          expr: |
            sum(count_over_time({kubernetes_namespace_name="demo-microservices", kubernetes_container_name="worker"} |= "Falha ao processar" [10m])) > 5
          for: 3m
          labels:
            severity: warning
            app: demo-microservices
            component: worker
          annotations:
            summary: "Worker com muitas falhas de processamento"
            description: "Mais de 5 falhas de processamento no worker nos ultimos 10 minutos."

        - alert: DatabaseConnectionLost
          expr: |
            count_over_time({kubernetes_namespace_name="demo-microservices"} |= "Conexao com banco perdida" [5m]) > 0
          for: 1m
          labels:
            severity: critical
            app: demo-microservices
            component: database
          annotations:
            summary: "Conexao com banco de dados perdida"
            description: "Um ou mais componentes perderam conexao com o PostgreSQL."

        - alert: ErrorBurstDetected
          expr: |
            sum(count_over_time({kubernetes_namespace_name="demo-microservices"} |= "ERROR BURST" [2m])) > 10
          for: 1m
          labels:
            severity: critical
            app: demo-microservices
          annotations:
            summary: "Burst de erros detectado na aplicacao"
            description: "Mais de 10 logs de ERROR BURST em 2 minutos."
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: microservices-metrics-alerts
  namespace: demo-microservices
  labels:
    openshift.io/cluster-monitoring: "true"
spec:
  groups:
    - name: microservices-pods
      rules:
        - alert: PodCrashLooping
          expr: |
            increase(kube_pod_container_status_restarts_total{namespace="demo-microservices"}[10m]) > 2
          for: 1m
          labels:
            severity: critical
            app: demo-microservices
          annotations:
            summary: "Pod em CrashLoopBackOff"
            description: "O container {{ $labels.container }} no pod {{ $labels.pod }} reiniciou mais de 2 vezes em 10 minutos."

        - alert: PodNotReady
          expr: |
            kube_pod_status_ready{namespace="demo-microservices", condition="true"} == 0
          for: 5m
          labels:
            severity: warning
            app: demo-microservices
          annotations:
            summary: "Pod nao esta Ready"
            description: "O pod {{ $labels.pod }} nao esta Ready ha mais de 5 minutos."

        - alert: HighMemoryUsage
          expr: |
            container_memory_working_set_bytes{namespace="demo-microservices", container!=""} / container_spec_memory_limit_bytes{namespace="demo-microservices", container!=""} > 0.85
          for: 5m
          labels:
            severity: warning
            app: demo-microservices
          annotations:
            summary: "Alto uso de memoria"
            description: "O container {{ $labels.container }} esta usando {{ $value | humanizePercentage }} da memoria limite."
EOF
```

### 1.7 Validar o Deploy

```bash
# Verificar todos os pods
oc get pods -n demo-microservices

# Resultado esperado:
# NAME                        READY   STATUS    RESTARTS
# api-xxxx                    1/1     Running   0
# api-xxxx                    1/1     Running   0
# database-xxxx               1/1     Running   0
# frontend-xxxx               1/1     Running   0
# frontend-xxxx               1/1     Running   0
# worker-xxxx                 1/1     Running   0
# worker-xxxx                 1/1     Running   0

# Pegar a URL da aplicacao
oc get route demo-microservices -n demo-microservices

# Testar a API
ROUTE=$(oc get route demo-microservices -n demo-microservices -o jsonpath='{.spec.host}')
curl -k https://$ROUTE/api/health
curl -k https://$ROUTE/api/info
curl -k -X POST https://$ROUTE/api/orders

# Verificar logs no Loki (console: Observe -> Logs)
# Query: {kubernetes_namespace_name="demo-microservices"} | json
```

---

## 2. Configurar Grafana para a Equipe de Dev ver Logs

### 2.1 Criar Datasources via Provisioning (Automatizado)

Em vez de configurar manualmente, vamos provisionar os datasources automaticamente.

**Pre-requisito:** O Grafana ja deve estar rodando (conforme secao 4.3 do `pos-upgrade-ocp-4.18.md`) e o token do `grafana-sa` deve estar disponivel.

```bash
# Gerar token de longa duracao para o Grafana
GRAFANA_TOKEN=$(oc create token grafana-sa -n grafana --duration=8760h)

# Criar ConfigMap de provisioning dos datasources
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: grafana
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus (OCP)
        type: prometheus
        access: proxy
        url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
        isDefault: true
        jsonData:
          httpHeaderName1: Authorization
          tlsSkipVerify: true
          timeInterval: 30s
        secureJsonData:
          httpHeaderValue1: "Bearer ${GRAFANA_TOKEN}"
        editable: true

      - name: Loki - Application Logs
        type: loki
        access: proxy
        url: https://logging-loki-gateway-http.openshift-logging.svc.cluster.local:8080/api/logs/v1/application
        jsonData:
          httpHeaderName1: Authorization
          tlsSkipVerify: true
          maxLines: 1000
        secureJsonData:
          httpHeaderValue1: "Bearer ${GRAFANA_TOKEN}"
        editable: true

      - name: Loki - Infrastructure Logs
        type: loki
        access: proxy
        url: https://logging-loki-gateway-http.openshift-logging.svc.cluster.local:8080/api/logs/v1/infrastructure
        jsonData:
          httpHeaderName1: Authorization
          tlsSkipVerify: true
          maxLines: 1000
        secureJsonData:
          httpHeaderValue1: "Bearer ${GRAFANA_TOKEN}"
        editable: true
EOF

# Atualizar o Deployment do Grafana para montar o ConfigMap
oc patch deployment grafana -n grafana --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "datasources",
      "mountPath": "/etc/grafana/provisioning/datasources"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "datasources",
      "configMap": {
        "name": "grafana-datasources"
      }
    }
  }
]'
```

> **Nota:** Se o patch falhar porque o Deployment ja tem volumes, edite diretamente com `oc edit deployment grafana -n grafana`.

### 2.2 Criar Dashboard de Logs para Devs

Este dashboard fornece uma visao completa dos logs por namespace, com filtros interativos.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards-provider
  namespace: grafana
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: 'OpenShift'
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards
          foldersFromFilesStructure: false
EOF
```

```bash
cat <<'DASHEOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-app-logs
  namespace: grafana
data:
  app-logs.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "id": null,
      "links": [],
      "panels": [
        {
          "title": "Volume de Logs por Nivel (ultimas 24h)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 0 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum by (level) (count_over_time({kubernetes_namespace_name=~\"$namespace\"} | json | level=~\"$level\" [$__interval]))",
              "legendFormat": "{{ level }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "custom": { "drawStyle": "bars", "stacking": { "mode": "normal" } },
              "color": { "mode": "palette-classic" }
            },
            "overrides": [
              { "matcher": { "id": "byName", "options": "error" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] },
              { "matcher": { "id": "byName", "options": "critical" }, "properties": [{ "id": "color", "value": { "fixedColor": "dark-red", "mode": "fixed" } }] },
              { "matcher": { "id": "byName", "options": "warning" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] },
              { "matcher": { "id": "byName", "options": "info" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] }
            ]
          }
        },
        {
          "title": "Erros por Container",
          "type": "piechart",
          "gridPos": { "h": 8, "w": 8, "x": 0, "y": 8 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum by (kubernetes_container_name) (count_over_time({kubernetes_namespace_name=~\"$namespace\"} |= \"error\" [$__range]))",
              "legendFormat": "{{ kubernetes_container_name }}",
              "refId": "A"
            }
          ]
        },
        {
          "title": "Taxa de Erros vs Total (ultimos 30min)",
          "type": "stat",
          "gridPos": { "h": 4, "w": 8, "x": 8, "y": 8 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum(count_over_time({kubernetes_namespace_name=~\"$namespace\"} | json | level=\"error\" [30m])) / sum(count_over_time({kubernetes_namespace_name=~\"$namespace\"} [30m])) * 100",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "thresholds": {
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 5 },
                  { "color": "red", "value": 15 }
                ]
              }
            }
          }
        },
        {
          "title": "Total de Logs (30min)",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 16, "y": 8 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum(count_over_time({kubernetes_namespace_name=~\"$namespace\"} [30m]))",
              "refId": "A"
            }
          ]
        },
        {
          "title": "Total de Erros (30min)",
          "type": "stat",
          "gridPos": { "h": 4, "w": 4, "x": 20, "y": 8 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum(count_over_time({kubernetes_namespace_name=~\"$namespace\"} | json | level=~\"error|critical\" [30m]))",
              "refId": "A"
            }
          ],
          "fieldConfig": { "defaults": { "color": { "fixedColor": "red", "mode": "fixed" } } }
        },
        {
          "title": "Top 10 Mensagens de Erro mais Frequentes",
          "type": "table",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 12 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "topk(10, sum by (message) (count_over_time({kubernetes_namespace_name=~\"$namespace\"} | json | level=~\"error|critical\" | keep message [$__range])))",
              "refId": "A"
            }
          ]
        },
        {
          "title": "Logs em Tempo Real",
          "type": "logs",
          "gridPos": { "h": 12, "w": 24, "x": 0, "y": 20 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "{kubernetes_namespace_name=~\"$namespace\", kubernetes_container_name=~\"$container\"} | json | level=~\"$level\"",
              "refId": "A"
            }
          ],
          "options": {
            "showTime": true,
            "showLabels": true,
            "showCommonLabels": false,
            "wrapLogMessage": true,
            "prettifyLogMessage": true,
            "enableLogDetails": true,
            "sortOrder": "Descending",
            "dedupStrategy": "none"
          }
        },
        {
          "title": "Logs de Request da API (com latencia)",
          "type": "logs",
          "gridPos": { "h": 10, "w": 24, "x": 0, "y": 32 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "{kubernetes_namespace_name=~\"$namespace\", kubernetes_container_name=\"api\"} | json | logger=\"api.request\" | line_format \"{{.method}} {{.path}} -> {{.status_code}} ({{.duration_ms}}ms) [{{.request_id}}]\"",
              "refId": "A"
            }
          ],
          "options": { "showTime": true, "wrapLogMessage": false, "enableLogDetails": true, "sortOrder": "Descending" }
        },
        {
          "title": "Latencia da API (P95 por path)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 42 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "quantile_over_time(0.95, {kubernetes_namespace_name=~\"$namespace\", kubernetes_container_name=\"api\"} | json | logger=\"api.request\" | unwrap duration_ms [$__interval]) by (path)",
              "legendFormat": "P95 - {{ path }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": { "unit": "ms", "custom": { "drawStyle": "line", "fillOpacity": 10 } }
          }
        },
        {
          "title": "Status Codes da API (distribuicao)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 50 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "sum by (status_code) (count_over_time({kubernetes_namespace_name=~\"$namespace\", kubernetes_container_name=\"api\"} | json | logger=\"api.request\" [$__interval]))",
              "legendFormat": "HTTP {{ status_code }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": { "custom": { "drawStyle": "bars", "stacking": { "mode": "normal" } } },
            "overrides": [
              { "matcher": { "id": "byRegexp", "options": "/2\\d\\d/" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] },
              { "matcher": { "id": "byRegexp", "options": "/4\\d\\d/" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] },
              { "matcher": { "id": "byRegexp", "options": "/5\\d\\d/" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }
            ]
          }
        },
        {
          "title": "Tasks do Worker (status)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 50 },
          "datasource": { "type": "loki", "uid": "" },
          "targets": [
            {
              "expr": "count_over_time({kubernetes_namespace_name=~\"$namespace\", kubernetes_container_name=\"worker\"} |= \"processado com sucesso\" [$__interval])",
              "legendFormat": "sucesso",
              "refId": "A"
            },
            {
              "expr": "count_over_time({kubernetes_namespace_name=~\"$namespace\", kubernetes_container_name=\"worker\"} |= \"Falha ao processar\" [$__interval])",
              "legendFormat": "falha",
              "refId": "B"
            }
          ],
          "fieldConfig": {
            "defaults": { "custom": { "drawStyle": "bars", "stacking": { "mode": "normal" } } },
            "overrides": [
              { "matcher": { "id": "byName", "options": "sucesso" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] },
              { "matcher": { "id": "byName", "options": "falha" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }
            ]
          }
        }
      ],
      "templating": {
        "list": [
          {
            "name": "namespace",
            "type": "custom",
            "current": { "text": "demo-microservices", "value": "demo-microservices" },
            "options": [
              { "text": "demo-microservices", "value": "demo-microservices", "selected": true },
              { "text": "demo-logging", "value": "demo-logging" },
              { "text": "demo-alerts", "value": "demo-alerts" },
              { "text": "Todos", "value": ".+" }
            ],
            "query": "demo-microservices,demo-logging,demo-alerts,.+",
            "includeAll": false,
            "multi": false
          },
          {
            "name": "container",
            "type": "custom",
            "current": { "text": "Todos", "value": ".+" },
            "options": [
              { "text": "Todos", "value": ".+", "selected": true },
              { "text": "api", "value": "api" },
              { "text": "worker", "value": "worker" },
              { "text": "nginx", "value": "nginx" },
              { "text": "postgres", "value": "postgres" }
            ],
            "query": ".+,api,worker,nginx,postgres",
            "includeAll": false,
            "multi": false
          },
          {
            "name": "level",
            "type": "custom",
            "current": { "text": "Todos", "value": ".+" },
            "options": [
              { "text": "Todos", "value": ".+", "selected": true },
              { "text": "info", "value": "info" },
              { "text": "warning", "value": "warning" },
              { "text": "error", "value": "error" },
              { "text": "critical", "value": "critical" },
              { "text": "error+critical", "value": "error|critical" }
            ],
            "query": ".+,info,warning,error,critical,error|critical",
            "includeAll": false,
            "multi": false
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "refresh": "30s",
      "schemaVersion": 39,
      "tags": ["logs", "application", "devteam"],
      "title": "Application Logs - Dev Team",
      "uid": "app-logs-devteam"
    }
DASHEOF
```

Agora monte os dashboards no Grafana:

```bash
oc patch deployment grafana -n grafana --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "dashboards-provider",
      "mountPath": "/etc/grafana/provisioning/dashboards"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "dashboards",
      "mountPath": "/var/lib/grafana/dashboards"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "dashboards-provider",
      "configMap": {
        "name": "grafana-dashboards-provider"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "dashboards",
      "configMap": {
        "name": "grafana-dashboard-app-logs"
      }
    }
  }
]'
```

### 2.3 Configurar Acesso da Equipe de Dev (RBAC no Grafana)

Para que a equipe de dev tenha acesso ao Grafana com permissoes adequadas, configure Organizations e Teams:

**Opcao A - Usuarios locais (lab/poc):**

Acessar o Grafana como admin e criar usuarios:

1. **Administration -> Users -> New user**
2. Criar usuarios para cada dev: `dev1`, `dev2`, etc
3. Atribuir role **Viewer** (podem ver dashboards e fazer queries, mas nao editar)

**Opcao B - Autenticacao via OpenShift OAuth (recomendado para producao):**

```bash
# Criar OAuthClient no OpenShift
cat <<'EOF' | oc apply -f -
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: grafana
grantMethod: auto
secret: grafana-oauth-secret-change-me
redirectURIs:
  - https://grafana-grafana.apps.ocp.177.54.151.49.sslip.io/login/generic_oauth
EOF

# Atualizar o Deployment do Grafana com variaveis de OAuth
GRAFANA_ROUTE=$(oc get route grafana -n grafana -o jsonpath='{.spec.host}')

oc set env deployment/grafana -n grafana \
  GF_AUTH_GENERIC_OAUTH_ENABLED=true \
  GF_AUTH_GENERIC_OAUTH_NAME="OpenShift" \
  GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana \
  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=grafana-oauth-secret-change-me \
  GF_AUTH_GENERIC_OAUTH_SCOPES="user:info" \
  GF_AUTH_GENERIC_OAUTH_AUTH_URL="https://oauth-openshift.apps.ocp.177.54.151.49.sslip.io/oauth/authorize" \
  GF_AUTH_GENERIC_OAUTH_TOKEN_URL="https://oauth-openshift.apps.ocp.177.54.151.49.sslip.io/oauth/token" \
  GF_AUTH_GENERIC_OAUTH_API_URL="https://openshift.default.svc.cluster.local/.well-known/oauth-authorization-server" \
  GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH="'Viewer'" \
  GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE=true \
  GF_SERVER_ROOT_URL="https://${GRAFANA_ROUTE}"
```

> Com OAuth, os devs fazem login no Grafana usando as mesmas credenciais do OpenShift.

### 2.4 Queries Uteis para a Equipe de Dev

Compartilhe estas queries LogQL com a equipe para uso no painel **Explore** do Grafana:

```
# Todos os logs de um namespace
{kubernetes_namespace_name="demo-microservices"} | json

# Filtrar por nivel de erro
{kubernetes_namespace_name="demo-microservices"} | json | level="error"

# Logs de um pod especifico
{kubernetes_namespace_name="demo-microservices", kubernetes_pod_name=~"api-.*"} | json

# Buscar por texto especifico nos logs
{kubernetes_namespace_name="demo-microservices"} |= "connection refused"

# Requests da API com latencia > 1000ms
{kubernetes_namespace_name="demo-microservices", kubernetes_container_name="api"} | json | logger="api.request" | duration_ms > 1000

# Contar erros por minuto
sum(count_over_time({kubernetes_namespace_name="demo-microservices"} | json | level="error" [1m]))

# Logs do worker com falhas
{kubernetes_namespace_name="demo-microservices", kubernetes_container_name="worker"} | json | level=~"error|warning"

# P99 de latencia da API agrupado por path
quantile_over_time(0.99, {kubernetes_namespace_name="demo-microservices", kubernetes_container_name="api"} | json | logger="api.request" | unwrap duration_ms [5m]) by (path)

# Logs de um request especifico (por request_id)
{kubernetes_namespace_name="demo-microservices"} | json | request_id="abc12345"

# Filtrar logs do Nginx por status 5xx
{kubernetes_namespace_name="demo-microservices", kubernetes_container_name="nginx"} | json | status_code >= 500
```

---

## 3. Testar Tudo

```bash
# 1. Pegar a URL da app
ROUTE=$(oc get route demo-microservices -n demo-microservices -o jsonpath='{.spec.host}')
echo "App: https://$ROUTE"

# 2. Criar pedidos (gera logs na API e no Worker)
for i in $(seq 1 20); do
  curl -sk -X POST https://$ROUTE/api/orders
  sleep 0.5
done

# 3. Gerar burst de erros
curl -sk -X POST "https://$ROUTE/api/simulate/error?type=burst&count=30"

# 4. Simular excecao
curl -sk -X POST "https://$ROUTE/api/simulate/error?type=exception"

# 5. Verificar no Grafana
GRAFANA_ROUTE=$(oc get route grafana -n grafana -o jsonpath='{.spec.host}')
echo "Grafana: https://$GRAFANA_ROUTE"
echo "Login: admin / admin123"
echo "Dashboard: Application Logs - Dev Team"

# 6. Verificar no OCP Console: Observe -> Logs
# Query: {kubernetes_namespace_name="demo-microservices"} | json
```

---

## Resumo da Arquitetura

```
                    +-----------+
                    |  Browser  |
                    +-----+-----+
                          |
                    +-----v-----+
                    |  Route     |
                    | (OCP TLS) |
                    +-----+-----+
                          |
                    +-----v-----+
                    | Frontend  |  Nginx (logs JSON)
                    | (2 pods)  |
                    +-----+-----+
                          |
                    +-----v-----+
                    |    API    |  Flask (logs estruturados JSON)
                    | (2 pods)  |  - /api/orders (CRUD)
                    +-----+-----+  - /api/tasks
                          |        - /api/simulate/error
                     +----+----+
                     |         |
               +-----v---+ +--v--------+
               | Database | |  Worker   |  Processamento async
               | Postgres | | (2 pods)  |  (logs JSON)
               | (1 pod)  | +-----------+
               +----------+
                                    |
                     +--------------v--------------+
                     |  Collector (Vector/Fluentd) |
                     |  DaemonSet em todos os nodes|
                     +--------------+--------------+
                                    |
                     +--------------v--------------+
                     |     LokiStack (Loki)        |
                     |  Armazenamento: S3 (AWS)    |
                     +--------------+--------------+
                           |                |
                    +------v------+  +------v------+
                    | OCP Console |  |   Grafana   |
                    | Observe->   |  | Dashboards  |
                    | Logs        |  | para Devs   |
                    +-------------+  +-------------+
```

## Proximos Passos

1. **Adicionar mais namespaces ao dropdown do dashboard** - edite a variavel `namespace` no dashboard para incluir novos projetos
2. **Criar dashboards especificos por equipe** - duplique o dashboard e ajuste os filtros
3. **Habilitar alertas no Grafana** - alem dos alertas via Loki Ruler, o Grafana pode ter seus proprios alertas com notificacao direta
4. **ServiceMonitor para metricas custom** - se a API exportar metricas Prometheus, crie um ServiceMonitor para coleta-las

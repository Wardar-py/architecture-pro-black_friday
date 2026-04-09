# Архитектурный документ: Оптимизация MongoDB и миграция на Cassandra (Python-реализация)

## Задание 7. Проектирование схем коллекций для шардирования данных

### 7.1 Коллекция `orders`

**Схема и индексы через PyMongo:**

```python
from pymongo import MongoClient, ASCENDING, DESCENDING
from pymongo.errors import OperationFailure

client = MongoClient('mongodb://mongos_router:27020')
db = client.somedb

# Создание коллекции с валидацией
db.create_collection('orders', validator={
    '$jsonSchema': {
        'bsonType': 'object',
        'required': ['order_id', 'customer_id', 'order_date', 'items', 'status', 'total_amount', 'geo_zone'],
        'properties': {
            'order_id': {'bsonType': 'string'},
            'customer_id': {'bsonType': 'string'},
            'order_date': {'bsonType': 'date'},
            'items': {
                'bsonType': 'array',
                'items': {
                    'bsonType': 'object',
                    'required': ['product_id', 'quantity', 'price'],
                    'properties': {
                        'product_id': {'bsonType': 'string'},
                        'quantity': {'bsonType': 'int'},
                        'price': {'bsonType': 'double'}
                    }
                }
            },
            'status': {
                'bsonType': 'string',
                'enum': ['pending', 'processing', 'shipped', 'delivered', 'cancelled']
            },
            'total_amount': {'bsonType': 'double'},
            'geo_zone': {'bsonType': 'string'}
        }
    }
})

# Шардирование: хешированный ключ по customer_id
client.admin.command('shardCollection', 'somedb.orders', key={'customer_id': 'hashed'})

# Индексы
db.orders.create_index([('order_id', ASCENDING)])  # уникальный
db.orders.create_index([('customer_id', ASCENDING), ('order_date', DESCENDING)])
```

**Обоснование:**

- customer_id (hashed) – равномерное распределение заказов по шардам.
- Поиск истории заказов пользователя попадает в один шард.
- Хеширование предотвращает «горячие» точки (популярные пользователи).

### 7.2 Коллекция products
```python
db.create_collection('products', validator={
    '$jsonSchema': {
        'bsonType': 'object',
        'required': ['product_id', 'name', 'category', 'price', 'stock_by_zone'],
        'properties': {
            'product_id': {'bsonType': 'string'},
            'name': {'bsonType': 'string'},
            'category': {'bsonType': 'string'},
            'price': {'bsonType': 'double'},
            'stock_by_zone': {
                'bsonType': 'object',
                'additionalProperties': {'bsonType': 'int'}
            },
            'attributes': {'bsonType': 'object'}
        }
    }
})

# шард-ключ: только hashed по product_id
client.admin.command('shardCollection', 'somedb.products', key={'product_id': 'hashed'})

# Индексы
db.products.create_index([('category', ASCENDING), ('price', ASCENDING)])
db.products.create_index([('product_id', ASCENDING)])
```
**Обоснование:**
- category группирует товары одной категории.
- product_id (hashed) – равномерное распределение внутри категории.
- Эффективный поиск по категориям и ценам, частые обновления остатков распределяются.

### 7.3 Коллекция carts

```python
db.create_collection('carts', validator={
    '$jsonSchema': {
        'bsonType': 'object',
        'required': ['_id', 'status', 'created_at', 'updated_at'],
        'properties': {
            '_id': {'bsonType': 'string'},
            'user_id': {'bsonType': 'string'},
            'session_id': {'bsonType': 'string'},
            'items': {
                'bsonType': 'array',
                'items': {
                    'bsonType': 'object',
                    'required': ['product_id', 'quantity'],
                    'properties': {
                        'product_id': {'bsonType': 'string'},
                        'quantity': {'bsonType': 'int'}
                    }
                }
            },
            'status': {
                'bsonType': 'string',
                'enum': ['active', 'ordered', 'abandoned']
            },
            'created_at': {'bsonType': 'date'},
            'updated_at': {'bsonType': 'date'},
            'expires_at': {'bsonType': 'date'}
        }
    }
})

# Шардирование по session_id (hashed) – покрывает и гостей, и авторизованных
client.admin.command('shardCollection', 'somedb.carts', key={'session_id': 'hashed'})

# Индексы
db.carts.create_index([('session_id', ASCENDING), ('status', ASCENDING)])
db.carts.create_index([('user_id', ASCENDING), ('status', ASCENDING)])
db.carts.create_index([('expires_at', ASCENDING)], expireAfterSeconds=0)
```
**Обоснование:**

- session_id – равномерное распределение корзин.
- TTL-индекс автоматически удаляет устаревшие корзины.
- Слияние корзин выполняется в одном шарде.


## Задание 8. Выявление и устранение «горячих» шардов

### 8.1 Метрики мониторинга

```python
import time
from pymongo import MongoClient

def collect_shard_metrics():
    client = MongoClient('mongodb://mongos_router:27020')
    config_db = client.get_database('config')
    
    # Количество чанков на шард
    chunks_per_shard = config_db.chunks.aggregate([
        {'$group': {'_id': '$shard', 'count': {'$sum': 1}}}
    ])
    
    # Размер данных (приблизительный)
    stats_per_shard = {}
    for shard in config_db.shards.find():
        shard_name = shard['_id']
        # Подключение к шарду напрямую
        shard_client = MongoClient(shard['host'])
        db_stats = shard_client.get_database('somedb').command('dbStats')
        stats_per_shard[shard_name] = {
            'dataSize': db_stats['dataSize'],
            'indexSize': db_stats['indexSize'],
            'collections': db_stats['collections']
        }
    
    # Latency (пример через serverStatus)
    latency = {}
    for shard_name, conn_info in stats_per_shard.items():
        shard_client = MongoClient(config_db.shards.find_one({'_id': shard_name})['host'])
        status = shard_client.admin.command('serverStatus')
        latency[shard_name] = status.get('opLatencies', {}).get('reads', {}).get('latency', 0)
    
    return {
        'chunks_per_shard': list(chunks_per_shard),
        'data_stats': stats_per_shard,
        'read_latency_ms': {k: v / 1000 for k, v in latency.items()}
    }

# Вывод метрик
metrics = collect_shard_metrics()
print(metrics)
```

**Ключевые метрики:**
- Количество документов / размер данных на шард.
- Количество чанков.
- Задержка чтения/записи.

### 8.2 Автоматическое перераспределение (балансировка)

```python
def rebalance_cluster(threshold_percent=20):
    client = MongoClient('mongodb://mongos_router:27020')
    config = client.get_database('config')
    
    # Получить количество чанков по шардам
    pipeline = [
        {'$group': {'_id': '$shard', 'chunks': {'$sum': 1}}}
    ]
    shard_chunks = {doc['_id']: doc['chunks'] for doc in config.chunks.aggregate(pipeline)}
    
    if not shard_chunks:
        return
    
    avg_chunks = sum(shard_chunks.values()) / len(shard_chunks)
    max_chunks = max(shard_chunks.values())
    imbalance = (max_chunks - avg_chunks) / avg_chunks * 100
    
    if imbalance > threshold_percent:
        # Запуск балансировщика
        client.admin.command('balancerStart')
        print(f"Балансировка запущена: дисбаланс {imbalance:.1f}%")
    else:
        print(f"Дисбаланс в пределах нормы ({imbalance:.1f}%)")

# Настройка окна балансировки
def set_balancer_window(start='00:00', stop='06:00'):
    client = MongoClient('mongodb://mongos_router:27020')
    client.get_database('config').settings.update_one(
        {'_id': 'balancer'},
        {'$set': {'activeWindow': {'start': start, 'stop': stop}}},
        upsert=True
    )

set_balancer_window()
rebalance_cluster()
```
**Обоснование:**
- Порог дисбаланса 20% – меньший порог (10%) вызывает лишние перемещения чанков, больший (30%) допускает длительную перегрузку шарда.  
- Окно балансировки 00:00–06:00 – наименее нагруженный период (по статистике распродаж), чтобы миграции не влияли на пользователей.  
- Запуск по cron каждые 15 минут – быстрее встроенного балансировщика MongoDB, что сокращает время существования «горячего» шарда.

## Задание 9. Настройка чтения с реплик и консистентность

### 9.1 Таблица операций чтения

| Коллекция         |      Операция       | Primary | Secondary | Допустимая задержка |                Обоснование |
|:------------------|:-------------------:|--------:|----------:|--------------------:|---------------------------:|
| products          | Поиск по категориям |       + |           |                 <1с | Частые обновления остатков |
| products          |   Описание товара   |         |         + |               5-10с |           Статичные данные |
| orders            |   Создание заказа   |       + |           |              <100мс |            Бизнес-критично |
| orders            |   История заказов   |         |         + |                1-5с |                Не критично |
| orders            |    Статус заказа    |       + |           |              <500мс |       Пользователь ожидает |
| carts             |  Получение корзины  |         |         + |                1-2с |         Допустима задержка |
| carts             | Обновление корзины  |       + |           |             <100мс  |   Строгая консистентность  |


### 9.2 Реализация Read Preferences на Python
```python
from pymongo import MongoClient, ReadPreference
from pymongo.write_concern import WriteConcern

client = MongoClient('mongodb://mongos_router:27020')
db = client.somedb

# 1. Чтение описания товара с secondary (допустима задержка)
def get_product_description(product_id: str):
    coll = db.products.with_options(
        read_preference=ReadPreference.SECONDARY_PREFERRED
    )
    return coll.find_one({'product_id': product_id})

# 2. Чтение статуса заказа только с primary (актуальность)
def get_order_status(order_id: str):
    coll = db.orders.with_options(
        read_preference=ReadPreference.PRIMARY
    )
    return coll.find_one({'order_id': order_id}, {'status': 1})

# 3. Создание заказа с write concern majority и транзакцией
def create_order(order_data: dict):
    with client.start_session() as session:
        session.start_transaction(
            write_concern=WriteConcern('majority', wtimeout=5000)
        )
        try:
            db.orders.insert_one(order_data, session=session)
            session.commit_transaction()
        except Exception:
            session.abort_transaction()
            raise

# 4. Получение корзины (чтение с secondary, задержка до 2с)
def get_cart(session_id: str = None, user_id: str = None):
    coll = db.carts.with_options(
        read_preference=ReadPreference.SECONDARY,
        read_concern={'level': 'local'},
        max_staleness_seconds=2000,
    )
    params = {'status': 'active'}
    if session_id:
        params.update({'session_id': session_id})
    elif user_id:
        params.update({'user_id': user_id})
    return coll.find_one(params)
```

### 9.3 Мониторинг задержки репликации

```python
def check_replication_lag():
    client = MongoClient('mongodb://mongos_router:27020')
    status = client.admin.command('replSetGetStatus')
    primary_optime = None
    lags = []
    
    for member in status['members']:
        if member['state'] == 1:  # PRIMARY
            primary_optime = member['optimeDate']
        elif member['state'] == 2:  # SECONDARY
            if primary_optime:
                lag = (primary_optime - member['optimeDate']).total_seconds()
                lags.append(lag)
                print(f"Replica {member['name']} lag: {lag:.2f}s")
    
    if lags and max(lags) > 5:
        print("⚠️  Задержка репликации превышает 5 секунд!")
    return max(lags) if lags else 0

check_replication_lag()
```

## Задание 10. Миграция на Cassandra

### 10.1 Выбор критически важных данных

| Сущность           |                         Причина миграции                         | Приоритет |
|:-------------------|:----------------------------------------------------------------:|----------:|
| Заказы             |   50k запросов/сек, критичны, нужна линейная масштабируемость    |   Высокий |
| Корзины            |             Временные данные, высокая частота записи             |   Высокий |
| История заказов    | Аналитика, огромный объём, не требуется строгая консистентность  |   Средний |


**Обоснование:**
- Заказы: высокая нагрузка записи (до 50000 запросов/сек), требуют линейной масштабируемости и отказоустойчивости. Cassandra обеспечивает leaderless репликацию и быстрое горизонтальное масштабирование без полного перераспределения данных.
- Корзины: временные данные с высокой частотой обновлений. Cassandra позволяет настроить TTL на уровне строки, автоматически очищая устаревшие корзины, и обеспечивает низкую задержку записи при высокой конкуренции.
- История заказов: аналитические данные, огромные объёмы, не требуется строгая консистентность. Cassandra с TimeWindowCompactionStrategy оптимизирует хранение по времени и эффективно работает с временными рядами.


### 10.2 Модель данных
```python
from cassandra.cluster import Cluster
from cassandra import ConsistencyLevel

session = Cluster(['cassandra1', 'cassandra2', 'cassandra3']).connect()
session.execute("""
    CREATE KEYSPACE IF NOT EXISTS shop
    WITH replication = {'class': 'NetworkTopologyStrategy', 'datacenter1': 3}
""")
session.set_keyspace('shop')

session.execute("""
    CREATE TYPE IF NOT EXISTS order_item (
        product_id text,
        quantity int,
        price decimal
    )
""")

session.execute("""
    CREATE TABLE IF NOT EXISTS orders_by_customer (
        customer_id text,
        order_date timestamp,
        order_id uuid,
        status text,
        total_amount decimal,
        geo_zone text,
        items frozen<list<order_item>>,
        PRIMARY KEY ((customer_id), order_date, order_id)
    ) WITH CLUSTERING ORDER BY (order_date DESC)
""")

session.execute("""
    CREATE TABLE IF NOT EXISTS orders_by_id (
        order_id uuid PRIMARY KEY,
        customer_id text,
        order_date timestamp,
        status text,
        total_amount decimal,
        geo_zone text,
        items frozen<list<order_item>>
    )
""")

session.execute("""
    CREATE TABLE IF NOT EXISTS carts_by_session (
        session_id text,
        updated_at timestamp,
        cart_id uuid,
        user_id text,
        status text,
        items frozen<list<order_item>>,
        created_at timestamp,
        PRIMARY KEY ((session_id), updated_at)
    ) WITH default_time_to_live = 86400
""")

session.execute("""
    CREATE TABLE IF NOT EXISTS carts_by_user (
        user_id text,
        updated_at timestamp,
        cart_id uuid,
        session_id text,
        status text,
        items frozen<list<order_item>>,
        created_at timestamp,
        PRIMARY KEY ((user_id), updated_at)
    ) WITH default_time_to_live = 86400
""")

session.execute("""
    CREATE TABLE IF NOT EXISTS order_history (
        date_bucket text,
        order_date timestamp,
        customer_id text,
        order_id uuid,
        total_amount decimal,
        status text,
        geo_zone text,
        PRIMARY KEY ((date_bucket), order_date, order_id)
    ) WITH CLUSTERING ORDER BY (order_date DESC)
      AND compaction = {
          'class': 'TimeWindowCompactionStrategy',
          'compaction_window_size': 7,
          'compaction_window_unit': 'DAYS'
      }
""")
```

**Обоснование:**
- **Таблица orders:** `PRIMARY KEY ((customer_id), order_date, order_id)`
  - `customer_id` как partition key – все заказы одного клиента хранятся на одной ноде, что позволяет быстро получать историю заказов без cross-node запросов.
  - `order_date` и `order_id` как кластерные ключи – сортировка по дате (DESC) для быстрого получения последних заказов.
- **Таблица carts:** `PRIMARY KEY ((session_id), updated_at)`
  - `session_id` – partition key, так как большинство операций с корзиной выполняются по сессии гостя или пользователя.
  - `updated_at` – кластеризация по времени обновления позволяет легко удалять старые корзины через TTL и сортировать по активности.
- **Таблица order_history:** `PRIMARY KEY ((date_bucket), order_date, order_id)`
  - `date_bucket` – партиционирование по дням для равномерного распределения аналитической нагрузки и эффективной фильтрации по датам.
  - `order_date` и `order_id` – кластеризация для хронологического порядка в каждой партиции.

### 10.3 Миграция данных из MongoDB в Cassandra

```python
from pymongo import MongoClient
from cassandra.cluster import Cluster
from cassandra.query import BatchStatement, SimpleStatement
import uuid

def migrate_orders(batch_size=100):
    mongo_client = MongoClient('mongodb://mongos_router:27020')
    cassandra_cluster = Cluster(['cassandra1'])
    cassandra_session = cassandra_cluster.connect('shop')
    
    batch = BatchStatement(consistency_level=ConsistencyLevel.QUORUM)
    count = 0
    
    orders = mongo_client.somedb.orders.find()
    for order in orders:
        query = SimpleStatement("""
            INSERT INTO orders 
            (customer_id, order_date, order_id, status, total_amount, geo_zone, items)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
        """)
        batch.add(query, (
            order['customer_id'],
            order['order_date'],
            order['order_id'],
            order['status'],
            order['total_amount'],
            order['geo_zone'],
            order['items']
        ))
        count += 1
        if count % batch_size == 0:
            cassandra_session.execute(batch)
            batch = BatchStatement()
            print(f"Migrated {count} orders")
    
    if batch:
        cassandra_session.execute(batch)
    print(f"Migration complete: {count} orders migrated")

migrate_orders()
```

**Обоснование:**
- **Hinted Handoff** – включён по умолчанию для всех таблиц. При временной недоступности узла запрос сохраняется на соседнем узле (до 3 часов). Критично для корзин и истории заказов, где потеря данных недопустима, а задержка доставки допустима.
- **Read Repair** – настроен с вероятностью 10% для таблицы orders. Заказы – бизнес-критичны, требуется высокая консистентность при чтении. Для корзин и истории вероятность read repair снижена до 1%, так как цена исправления ошибок выше выигрыша в консистентности.
- **Anti-Entropy Repair** – запускается еженедельно для всех таблиц. Полное сканирование необходимо для синхронизации данных после длительной работы, особенно при сбоях. Частота – 7 дней, так как daily repair излишне нагружает кластер, а monthly рискованно.

### 10.4 Стратегии консистентности (настройка уровней)

```python
from cassandra import ConsistencyLevel

# Для заказов – QUORUM запись, QUORUM чтение
def insert_order_quorum(order_data):
    query = SimpleStatement(
        "INSERT INTO orders_by_customer (...) VALUES (...)",
        consistency_level=ConsistencyLevel.QUORUM
    )
    session.execute(query)

def get_order_quorum(order_id):
    query = SimpleStatement(
        "SELECT * FROM orders WHERE order_id = %s",
        consistency_level=ConsistencyLevel.QUORUM
    )
    return session.execute(query, [order_id])

# Для корзин – ONE запись, ONE чтение (скорость)
def update_cart_one(cart_data):
    query = SimpleStatement(
        "UPDATE carts SET items = %s WHERE session_id = %s",
        consistency_level=ConsistencyLevel.ONE
    )
    session.execute(query)

# Для истории – ONE запись
def insert_history_one(history_data):
    query = SimpleStatement(
        "INSERT INTO order_history (...) VALUES (...)",
        consistency_level=ConsistencyLevel.ONE
    )
    session.execute(query)
```

**Обоснование:**
- **Orders** – `QUORUM` для записи и чтения. Заказы должны быть строго консистентны, чтобы избежать дублирования или потери. QUORUM даёт баланс между доступностью и целостностью.
- **Carts** – `ONE` для записи и чтения. Скорость важнее абсолютной консистенции; временная потеря корзины не критична, пользователь просто добавит товары заново.
- **Order_history** – `ONE` для записи, `ONE` для чтения. Аналитика может пережить eventual consistency; запись не должна блокироваться даже при частичном отказе узлов.

### 10.5 Мониторинг и восстановление целостности (команды nodetool)

**Ключевые команды nodetool для мониторинга:**

```bash
# 1. Статус кластера (состояние узлов, нагрузка)
nodetool status

# 2. Детальная информация об узле (uptime, нагрузка, heap memory)
nodetool info

# 3. Статистика по пулам потоков (ключевой индикатор – поле Pending)
nodetool tpstats

# 4. Задержки чтения/записи (перцентили)
nodetool proxyhistograms

# 5. Статистика по таблицам (размеры, количество SSTable)
nodetool cfstats shop.orders
nodetool cfstats shop.carts
nodetool cfstats shop.order_history

# 6. Размер очереди hinted handoff
nodetool statushandoff

# 7. Время последнего repair
nodetool netstats | grep -A 3 "Repair"
```

**Обоснование:**
- **Hinted Handoff**: включён для всех таблиц
- **Ключевые метрики** (через `nodetool`): задержка записи/чтения (перцентили 95, 99), размер очереди hinted handoff, время последнего успешного repair.
- **Пороги и действия:** задержка > 50 мс - увеличить количество узлов или проверить сеть; очередь hinted handoff > 10000 → возможен сбой узла, запустить ручной repair; repair не запускался > 7 дней → принудительный запуск `nodetool repair -pr`.
- **Автоматическое восстановление** – скрипт мониторинга на Python вызывает `nodetool repair` при обнаружении расхождений и отправляет алерт в Prometheus/Alertmanager.

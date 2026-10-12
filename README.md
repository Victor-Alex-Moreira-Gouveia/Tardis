# Tardis — Servidor Pessoal & Central de Automação

**Descrição:** O projeto consiste em um servidor caseiro para hospedar aplicações web e ferramentas de produtividade e automação, eliminando custos com serviços de Cloud para projetos de pequeno e médio porte.

O hardware base utilizado é um **Raspberry Pi 4 Model B** (8 GB de RAM, CPU de 1,5 GHz). Este servidor recebe o hostname de `tardis-core01`. Caso haja necessidade de expansão futura, bastará replicar a infraestrutura em novos nós.

---

## Arquitetura e Ecossistema (Docker Compose)

O servidor opera de forma centralizada utilizando uma rede interna Docker (`server_net`) e um **Nginx** atuando como Proxy Reverso na porta `80`. Nenhuma aplicação expõe portas diretamente para o host, exceto o Nginx.

### Serviços Incluídos:
1. **PostgreSQL (`DB_Server`):** Banco de dados centralizado otimizado para o ecossistema.
2. **Nextcloud (`nextcloud_app`):** Plataforma de armazenamento e colaboração em nuvem.
3. **Collabora Online (`collabora_app`):** Suíte de escritório integrada ao Nextcloud para edição de documentos (Word, Excel, PPT) via navegador.
4. **n8n (`n8n_app`):** Ferramenta de automação de workflows.
5. **Nginx (`nginx_proxy`):** Ponto de entrada único responsável pelo roteamento baseado em subdomínios.

---

## Estrutura de Diretórios

```text
.
├── databases/
│   └── init_server.sql       # Script executado automaticamente pelo Postgres na 1ª inicialização
├── postgres_data/            # Volume persistente do Banco de Dados
├── nextcloud_data/           # Volume persistente dos arquivos do Nextcloud
├── n8n_data/                 # Volume persistente dos fluxos do n8n
├── docker-compose.yml        # Orquestração de todos os containers
├── nginx.conf                # Configuração de rotas e subdomínios do Nginx
└── .env                      # Variáveis de ambiente sensíveis
```

---

## Inicialização do Banco de Dados (`./databases`)

O diretório `./databases` é mapeado diretamente para o mecanismo de inicialização do PostgreSQL (`/docker-entrypoint-initdb.d:ro`). Qualquer arquivo `.sql` colocado nele na primeira execução será processado automaticamente.

Exemplo do script `./databases/init_server.sql`:

```sql
CREATE TABLE server_identity (
    id SERIAL PRIMARY KEY,
    server_name VARCHAR(100) NOT NULL,
    server_uuid UUID DEFAULT gen_random_uuid(),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO server_identity(server_name)
VALUES ('Raspberry Pi 4B - Tardis');

```
---

## Configuração de Variáveis de Ambiente (`.env`)

Crie um arquivo `.env` na raiz do projeto com base nas credenciais abaixo. **Nunca envie o arquivo `.env` para repositórios públicos.**

```env
# Configurações do Banco de Dados
DB_USER=root
DB_PASSWORD=sua_senha_segura_aqui
DB_DATABASE=tardis_db

# Gateway de Rede Local
IP_GATEWAY=192.168.1.1

# Credenciais de Administrador do Nextcloud
NEXTCLOUD_ADMIN_USER=root
NEXTCLOUD_ADMIN_PASSWORD=sua_senha_admin_nextcloud

# Domínio do Tailscale (Utilizado em Produção)
TAILSCALE_DOMAIN=tardis-core01.tail1234.ts.net

```
---

## Modos de Operação e Teste

### 1. Ambiente de Testes Locais (Fedora / Sem Tailscale)

Ideal para validar alterações na sua máquina local antes de enviar para o Raspberry Pi.

1. **Configurar o arquivo de hosts (`/etc/hosts`):**
Adicione os domínios locais no seu computador:
```text
127.0.0.1 nextcloud.local n8n.local collabora.local

```


2. **Ajustes no Docker Compose para Local:**
* Garanta que o n8n possua a variável `- N8N_SECURE_COOKIE=false` (para aceitar HTTP puro).
* Configure os domínios confiáveis do Nextcloud para `nextcloud.local localhost 127.0.0.1`.
* Configure o Collabora com `extra_params=--o:ssl.enable=false --o:ssl.termination=false` e `'aliasgroup1=http://.*'`.


3. **Como acessar:**
* Nextcloud: `http://nextcloud.local`
* n8n: `http://n8n.local`
* Collabora: `http://collabora.local`



---

### 2. Ambiente de Produção (Raspberry Pi / Com Tailscale e MagicDNS)

Utiliza o túnel criptografado do Tailscale para acesso seguro de dentro e de fora de casa.

1. **Configurar o MagicDNS:**
Certifique-se de que o Tailscale está ativo no Raspberry Pi e obtenha o seu domínio (ex: `tardis-core01.tail1234.ts.net`).
2. **Ajustes no Docker Compose para Produção:**
* Atualize o arquivo `.env` com o seu `TAILSCALE_DOMAIN`.
* Configure os subdomínios no `nginx.conf` utilizando o domínio do Tailscale (ex: `server_name nextcloud.tardis-core01.tail1234.ts.net;`).
* No Collabora, utilize `ssl.termination=true` e aponte o alias para o Nextcloud seguro do Tailscale.


3. **Como acessar:**
* De qualquer dispositivo conectado à sua rede Tailscale:
* `http://nextcloud.tardis-core01.tail1234.ts.net`
* `http://n8n.tardis-core01.tail1234.ts.net`
* `http://collabora.tardis-core01.tail1234.ts.net`





---

## Como Subir a Infraestrutura

1. Certifique-se de ajustar as permissões da pasta do n8n (necessário para evitar erros de permissão do container):
```bash
sudo mkdir -p n8n_data
sudo chown -R 1000:1000 n8n_data
```


2. Suba todos os serviços em segundo plano:
```bash
docker compose up --build -d
```


3. Acompanhe os logs gerais ou de um serviço específico para validar a inicialização:
```bash
docker compose logs -f
```
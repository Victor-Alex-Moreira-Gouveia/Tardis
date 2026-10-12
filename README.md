# Tardis — servidor pessoal, colaboração e automação

O Tardis roda em um Raspberry Pi e reúne Nextcloud, Collabora Online, n8n, PostgreSQL e Nginx. O repositório guarda o código e os procedimentos. Os dados de produção e segredos ficam no Pi, fora do Git.

## Pastas de produção no Raspberry Pi

    /home/vamg/Desktop/services/
    ├── Tardis-source-2026/  # clone Git e Compose usado pelos containers
    └── server/              # .env, bancos, arquivos Nextcloud e dados do n8n

As duas pastas são necessárias. Tardis-source-2026 é o checkout que controla os containers. server contém dados persistentes e segredos montados nos containers; não apague, mova ou substitua essa pasta durante uma atualização do Git. O clone antigo Tardis-git foi removido depois de confirmar que estava limpo, no mesmo commit e sem containers usando seus arquivos.

O Compose em execução usa:

    /home/vamg/Desktop/services/Tardis-source-2026/docker-compose.yml
    /home/vamg/Desktop/services/Tardis-source-2026/tardis-production.override.yml

O override real do Pi contém nomes de imagem e volume específicos do host, por isso não é enviado ao GitHub. A cópia semanal guarda esse arquivo e a configuração real do Nginx. O arquivo tardis-production.override.example.yml serve como modelo sem o identificador do volume PostgreSQL.

### Dados que precisam permanecer

- Nextcloud: server/nextcloud_data em /var/www/html.
- n8n: server/n8n_data em /home/node/.n8n.
- PostgreSQL: volume Docker externo montado em /var/lib/postgresql/data; o nome real fica apenas no override local do Pi.
- server/postgres_data é uma montagem separada em /var/lib/postgresql; ela não é o PGDATA ativo.
- server/.env, server/databases e os arquivos de produção contêm credenciais ou dados necessários à recuperação.

O modelo tardis-production.override.example.yml usa as variáveis TARDIS_SERVER_DIR, TARDIS_REPO_DIR, TAILSCALE_DNS_NAME e POSTGRES_ACTIVE_VOLUME. Defina-as no .env local antes de adaptar o modelo; nunca envie o .env ao GitHub.

Confirme os mounts reais com docker inspect antes de qualquer atualização ou recuperação. Não use docker compose down -v, docker volume prune nem remova pastas de dados.

## Acesso pelo Tailscale

O Tailscale Serve termina HTTPS e encaminha para os serviços locais. O acesso permanece privado aos dispositivos aceitos pelo tailnet; MagicDNS não resolve para dispositivos sem Tailscale.

| Serviço | Endereço |
| --- | --- |
| Nextcloud | https://<NOME-MAGICDNS>/ |
| Collabora | https://<NOME-MAGICDNS>:8443/ |
| n8n | https://<NOME-MAGICDNS>:8444/ |

Use HTTPS. Abra documentos pelo Nextcloud; o Collabora conversa com ele pela rede Docker e pode responder apenas OK quando sua raiz é acessada diretamente.

## Backup semanal

O serviço tardis-backup.service é executado pelo timer tardis-backup.timer aos domingos às 03:00, no fuso horário do Pi. Persistent=true permite que o systemd execute o backup perdido quando o Pi voltar a ligar.

O script de backup:

1. exige pelo menos 10 GiB livres no destino;
2. ativa o modo de manutenção do Nextcloud, se ele ainda não estiver ativo, e para o n8n de forma controlada;
3. gera um dump customizado do banco tardis_db com PostgreSQL 16;
4. arquiva todos os dados do Nextcloud e do n8n, as configurações de produção, o .env e um bundle Git;
5. reinicia os serviços, confere os arquivos compactados e o dump, gera SHA-256 e só então marca a cópia como completa;
6. conserva as 12 cópias semanais completas mais recentes.

As cópias ficam em /var/backups/tardis-weekly/, no mesmo Raspberry Pi. Esse destino atende à decisão atual, mas não protege contra perda do próprio Pi. Um backup válido ainda depende de uma restauração ensaiada; até o primeiro ensaio, considere a recuperação operacional não comprovada.

Comandos de consulta:

    systemctl list-timers tardis-backup.timer
    systemctl status tardis-backup.timer
    journalctl -u tardis-backup.service
    sudo bash -c 'cd /var/backups/tardis-weekly/DIRETORIO_DO_BACKUP && sha256sum -c SHA256SUMS'
    sudo /home/vamg/Desktop/services/server/restore.sh /var/backups/tardis-weekly/DIRETORIO_DO_BACKUP /var/tmp/tardis-restore-DATA

O arquivo COMPLETE.txt só aparece depois da verificação de integridade. Uma pasta sem esse marcador é uma execução incompleta e não deve ser usada como recuperação.

### Ativar as mensagens no Slack

O canal privado #tardis-backups já foi criado. O timer pode fazer cópias sem uma URL do Slack, mas ainda não envia mensagens até que a Incoming Webhook seja configurada.

1. Crie uma Slack App ou use uma app existente, habilite Incoming Webhooks e adicione uma webhook ao canal privado #tardis-backups.
2. No Pi, rode:

       sudo /home/vamg/Desktop/services/Tardis-source-2026/scripts/configure-slack-webhook.sh

3. Cole a URL na solicitação oculta do terminal. O script envia uma mensagem de conexão e salva a URL apenas em /etc/tardis-backup.env, legível somente por root. Nunca coloque a URL no Git, em um issue ou nesta conversa.

O Slack vincula cada URL de webhook a um canal e trata a URL como segredo. Consulte a documentação oficial do Slack em https://api.slack.com/messaging/webhooks. Mensagens semanais incluem sucesso ou falha, tamanho e horário da cópia.

## Recuperação

Cada cópia semanal contém tardis_db.dump (formato customizado do pg_dump), os arquivos Nextcloud e n8n, .env, os scripts de inicialização do PostgreSQL, Compose base e override real, Nginx real, status do host e bundle Git.

Verificações automáticas de SHA-256, abertura dos arquivos tar e leitura do catálogo PostgreSQL confirmam a integridade dos artefatos. O comando server/restore.sh DIRETORIO_DO_BACKUP DIRETORIO_NOVO prepara uma extração isolada depois de conferir checksums, arquivos, dump e bundle Git; ele não troca os dados de produção nem sobe containers. Isso substitui o antigo restore.sh, que copiava um SQL para docker-entrypoint-initdb.d e não restaurava o volume ativo.

Antes de restaurar:

1. use uma cópia que contenha COMPLETE.txt e execute o preparo em um destino novo fora de /home/vamg/Desktop/services;
2. crie um PostgreSQL 16 novo e confirme os usuários root e oc_admin antes de importar tardis_db.dump com pg_restore;
3. recupere os dados Nextcloud e n8n junto da configuração correspondente, incluindo a chave de criptografia do n8n;
4. só troque os mounts de produção depois de verificar o banco e os arquivos restaurados.

O ensaio de restauração em ambiente isolado ainda precisa ser feito antes de declarar o procedimento plenamente comprovado. Preserve a cópia anterior do volume PostgreSQL até que o ensaio passe.

## Atualizar o projeto pelo GitHub

O repositório usa HTTPS e a branch remota principal é main. O Pi estava com a autenticação antiga do GitHub inválida; autentique novamente uma vez:

    gh auth login --hostname github.com --git-protocol https --web
    gh auth setup-git

Depois, no clone ativo. Como o checkout de produção mantém uma branch de trabalho, atualize-a sobre `main` sem trocar para outra branch e remover os scripts do timer:

    cd /home/vamg/Desktop/services/Tardis-source-2026
    git status --short
    git fetch origin
    git rebase origin/main

Comece com a árvore de trabalho limpa. Se houver conflitos, resolva-os, use `git add` nos arquivos resolvidos e rode `git rebase --continue`; para cancelar, use `git rebase --abort`.

Para enviar alterações próprias, crie uma branch, revise o diff, faça commit e publique a branch:

    git switch -c minha-alteracao
    git diff
    git add README.md scripts systemd .gitignore tardis-production.override.example.yml
    git commit -m "Descreva a alteração"
    git push -u origin minha-alteracao

Os arquivos .env, tardis-production.override.yml, nginx.production.conf e os diretórios de dados estão excluídos do Git. A atualização do clone, sozinha, não altera os containers em execução. Antes de publicar uma nova versão na produção, faça e confira um backup, revise as imagens e os mounts, valide a configuração Compose com o .env protegido e só então aplique o deploy.

## Monitoramento

O diretório monitoramento_server ainda contém scripts antigos, mas não havia processo, serviço ou timer de monitoramento ativo na verificação. O timer desta documentação cobre o backup e a respectiva notificação. Configure monitoramento separado depois de definir métricas, destinatário e frequência desejados.

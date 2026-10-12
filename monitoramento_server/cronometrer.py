import os
import datetime
import threading
import calendar
import time
from monitor import enviar_alerta_slack

# Passo 1: Checkar todo dia se o dia é igual apos 7 dia
# Passo 2: Depois de 7 dia tem que executar o ./backup.sh (usando sudo)
# Passo 3: Enviar mensagem no Slack que o backup foi realizado com sucesso
# Passo 4: Definir próxima data de backup
# Passo 5: Salvar registros de backup em um banco de dados

def Backup():
    print("Fazendo backup de brinks para teste")
    
def Salvando_registros():
    print("Salvando hostórico de backup")

hoje = datetime.date.today()
next_backup = hoje + datetime.timedelta(days=7) # proxima data não pode ser somada a partir daqui se não vai haver um loop que troca a data de hoje
diferencao = next_backup - hoje

if (diferencao == 7):
    Backup()
elif (diferencao > 7):
    print("Passou um pouco da data")
    Backup()
    Salvando_registros()
    enviar_alerta_slack(f"Backup do sistema realizado em {hoje}, {diferencao}")

print(diferencao)
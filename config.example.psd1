# Copie este arquivo para config.psd1 e preencha.  /  Copy to config.psd1 and fill in.
#
#   Copy-Item config.example.psd1 config.psd1
#
# config.psd1 e bloqueado pelo .gitignore. NUNCA faca commit dele.
# config.psd1 is gitignored. NEVER commit it.
#
# Os valores vem do README do SEU pacote do EBS. Este repositorio contem
# apenas a automacao -- nenhuma credencial, nenhum link para os dados.
# The values come from YOUR EBS package README. This repository holds only
# the automation -- no credentials, no links to the data.

@{
    # RECOMENDADO: URL base de um bucket/host HTTP com as partes e o
    # manifest.txt (Cloudflare R2, S3, qualquer servidor com suporte a Range).
    # Sem cota, sem scraping, e o curl -C - retoma byte-exato.
    # RECOMMENDED: base URL of an HTTP bucket/host holding the parts and
    # manifest.txt. No quota, no scraping, byte-exact resume.
    BaseUrl      = 'https://pub-SEU_HASH.r2.dev'

    # Alternativa: pasta publica do Google Drive. Funciona, mas depende de
    # scraping do HTML e a cota de download interrompe transferencias grandes.
    # Alternative: public Google Drive folder. Works, but relies on HTML
    # scraping and the download quota interrupts large transfers.
    # FolderUrl  = 'https://drive.google.com/drive/folders/COLOQUE_O_ID_AQUI'

    # Senha do WebLogic (obrigatoria) / WebLogic password (required)
    WlsPassword  = ''

    # Senha do schema APPS (padrao 'apps') / APPS schema password (defaults to 'apps')
    AppsPassword = 'apps'

    # Hostname que o EBS gravou no contexto / hostname baked into the EBS context
    AppsHost     = 'apps.example.com'

    # Onde instalar. Deixe COMENTADO para o script escolher sozinho o drive
    # com mais espaco livre -- cada maquina tem um setup de discos diferente,
    # e cravar uma letra aqui quebra em toda maquina que nao a tenha.
    # Where to install. Leave COMMENTED OUT to let the script pick the drive
    # with the most free space; hardcoding a letter breaks on machines
    # that do not have it.
    # TargetDir  = 'C:\R12OnContainer'
}

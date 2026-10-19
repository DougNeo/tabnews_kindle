# TabNews para KOReader

[![Testes](https://github.com/DougNeo/tabnews_kindle/actions/workflows/test.yml/badge.svg)](https://github.com/DougNeo/tabnews_kindle/actions/workflows/test.yml)
[![Última versão](https://img.shields.io/github/v/release/DougNeo/tabnews_kindle?label=vers%C3%A3o)](https://github.com/DougNeo/tabnews_kindle/releases/latest)

Leia o [TabNews](https://www.tabnews.com.br) no seu e-reader, como se fosse um livro. Os posts viram documentos do KOReader, com as suas fontes, margens e realces, e ficam salvos para ler offline.

## O que dá para fazer

- **Edição do dia:** os 10 posts mais relevantes num único documento com índice, como um jornal
- **Relevantes e Recentes:** listas com tabcoins, número de comentários e tempo de leitura
- **Leitura offline:** cada post é salvo com imagens e comentários
- **Busca:** na web, no índice de títulos e no texto completo dos posts salvos, inclusive sem internet
- **Autores favoritos:** uma lista só com os posts de quem você segue
- **Esconder categorias:** cansou dos posts `Pitch:`? Esconda todos com dois toques
- **Tabcoins:** dê +1 ou −1 no post que você está lendo
- **Comentários novos:** a lista avisa com `(+3)` quando chegam comentários num post que você já baixou
- **Sincronização automática** ao conectar no Wi-Fi, com opção de desligar o Wi-Fi no final para economizar bateria
- **Atualizações automáticas:** o plugin avisa quando sai versão nova e se atualiza sozinho

Tabelas, listas, blocos de código, links e imagens dos posts aparecem formatados.

## Requisitos

- Um e-reader com o [KOReader](https://koreader.rocks) instalado. No Kindle, isso exige o aparelho desbloqueado (jailbreak).
- Wi-Fi para baixar os posts. Depois de baixados, eles ficam disponíveis offline.

Testado no Kindle. Deve funcionar em Kobo, PocketBook e Android com KOReader. Se você testar, conte nas [issues](https://github.com/DougNeo/tabnews_kindle/issues)!

## Instalação

1. Baixe o arquivo **`tabnews.koplugin.zip`** da [última versão](https://github.com/DougNeo/tabnews_kindle/releases/latest).
2. Descompacte. Vai aparecer uma pasta chamada `tabnews.koplugin`.
3. Conecte o e-reader no computador pelo cabo USB.
4. Copie a pasta `tabnews.koplugin` para dentro da pasta `plugins` do KOReader:

   | Aparelho   | Pasta de destino                      |
   |------------|---------------------------------------|
   | Kindle     | `koreader/plugins/`                   |
   | Kobo       | `.kobo/koreader/plugins/` (pasta oculta) |
   | Android    | `koreader/plugins/` (no armazenamento interno) |

   Em outros aparelhos, procure a pasta `plugins` dentro da pasta onde o KOReader está instalado.

5. Ejete o aparelho com segurança e reinicie o KOReader.

O plugin aparece no menu **Ferramentas (ícone de chave inglesa) → TabNews**.

> **Confira a pasta:** o arquivo `main.lua` precisa ficar em `plugins/tabnews.koplugin/main.lua`. Se ficar em `plugins/tabnews.koplugin/tabnews.koplugin/main.lua`, o plugin não aparece.

## Primeiros passos

1. Ligue o Wi-Fi e abra **TabNews → Sincronizar agora**. Ele baixa os posts mais relevantes, monta a edição do dia e prepara a busca. A primeira vez demora um pouco mais.
2. Abra **TabNews → Edição do dia** e boa leitura!

Algumas dicas:

- **Segure o dedo num post da lista** para seguir o autor, esconder a categoria ou baixar para ler depois.
- **Lendo um post**, use **TabNews → Post aberto** para atualizar os comentários, dar tabcoins ou seguir o autor.
- Em **TabNews → Configurações** você liga a sincronização automática e o desligamento do Wi-Fi.
- Para cancelar uma sincronização, toque na mensagem de progresso.

## Atualizações

Você só instala manualmente uma vez. Depois disso, o plugin procura versões novas durante a sincronização (no máximo uma vez por dia) e pergunta se pode atualizar. Para checar na hora, use **TabNews → Configurações → Verificar atualização**.

## Perguntas frequentes

**O plugin não aparece no menu.**
Confira se a pasta ficou no lugar certo (veja o aviso na instalação) e reinicie o KOReader. No Kindle, reiniciar pelo menu do KOReader é suficiente.

**A busca diz "só títulos".**
A busca na web usa o DuckDuckGo, que às vezes bloqueia acessos automáticos. Nesse caso o plugin busca nos títulos dos posts recentes e no texto dos posts salvos. Tente de novo mais tarde para ter os resultados da web.

**Minha senha fica salva no aparelho?**
Não. Ao entrar na conta, o plugin guarda apenas o token de sessão que o TabNews devolve (válido por 30 dias). Para sair, use **Configurações → Conta**.

**Onde ficam os arquivos?**
Os posts salvos ficam em `koreader/tabnews/`. Posts que você não abre há 30 dias são apagados automaticamente (dá para desligar em Configurações).

**Encontrei um problema.**
Abra uma [issue](https://github.com/DougNeo/tabnews_kindle/issues) contando o modelo do aparelho e o que aconteceu. Se possível, inclua as linhas com "TabNews" do arquivo `koreader/crash.log`.

## Para desenvolvedores

Os testes rodam sem KOReader e sem rede, só com LuaJIT:

```bash
luajit tests/run.lua
```

Para publicar uma versão, atualize `VERSION` em `tabnews.koplugin/main.lua` e envie uma tag com o mesmo número:

```bash
git tag v1.0 && git push origin main --tags
```

O GitHub Actions roda os testes, confere a versão, gera o zip e publica a release. Os aparelhos com o plugin instalado recebem a atualização na próxima sincronização.

Contribuições são bem-vindas: abra uma issue ou um pull request.

---

Projeto não oficial, feito pela comunidade. Usa a API pública do TabNews. Licença MIT.

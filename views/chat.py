"""Aba Chat — conversa estilo WhatsApp 1-pra-1 com auto-refresh 2s.

Com `st.navigation`, esta view só roda quando o user está nela. O fragmento
`_global_notif` (toast de msg nova) está montado na sidebar do app.py pra
continuar disparando em qualquer view.
"""

from __future__ import annotations

from datetime import datetime

import streamlit as st

import database as db

from core.chat_utils import _render_chat_messages
from core.data import _load_df_u


usuario = st.session_state.usuario
df_u = _load_df_u()


st.header("💬 Chat Interno")
st.caption(
    "🟢 Tempo real — mensagens novas aparecem em até 2 segundos sem "
    "precisar atualizar."
)

# 1. Seleção de Contato com badge de não-lidas por usuário
lista_usuarios = df_u["nome"].tolist() if not df_u.empty else []
if usuario in lista_usuarios:
    lista_usuarios.remove(usuario)

# Mapa "remetente → qtd não lidas" pra mostrar (N) ao lado do nome.
# Sara Borges (3) · Leticia · Rodrigo (1)
_nao_lidas_por_user = dict(
    db.listar_remetentes_com_nao_lidas(usuario)
)
# Ordena: quem tem não-lidas vai pro topo, depois alfabético.
# Esse sort também serve de UX default: sem `_chat_force_target` setado, o
# selectbox abre em quem tem mais mensagens pendentes.
lista_usuarios.sort(
    key=lambda n: (-int(_nao_lidas_por_user.get(n, 0)), n.lower())
)


def _fmt_contato(nome):
    _q = int(_nao_lidas_por_user.get(nome, 0))
    return f"🔴 {nome} ({_q})" if _q > 0 else nome


# ── PRÉ-SELEÇÃO DO CONTATO (à prova de bug) ────────────────
# `_chat_force_target` é a ÚNICA fonte de redirect explícito. Setado pelo
# boot quando o user clica no toast (`?_goto_chat=NOME`) ou pelo handler
# de envio de msg (pra manter o user na mesma conversa após rerun).
#
# ESTRATÉGIA À PROVA DE BUG: setar `st.session_state[widget_key]` antes do
# widget NEM SEMPRE é honrado — o Streamlit às vezes mantém o estado interno
# de reruns anteriores. Em vez disso:
#   1. DELETAR a key (força reconstrução do zero).
#   2. Passar `index=` explícito.
# Determinístico em qualquer versão do Streamlit.
_target = st.session_state.pop("_chat_force_target", None)
_default_index = 0
if _target:
    # Match exato + fallback case-insensitive/strip pra blindar contra
    # whitespace, encoding URL, normalização Unicode.
    _hit = _target if _target in lista_usuarios else None
    if _hit is None:
        _tnorm = str(_target).strip().lower()
        for _nome in lista_usuarios:
            if str(_nome).strip().lower() == _tnorm:
                _hit = _nome
                break
    if _hit is not None:
        _default_index = lista_usuarios.index(_hit)
        if "sel_contato_final_v2" in st.session_state:
            del st.session_state["sel_contato_final_v2"]

contato = st.selectbox(
    "Conversar com:",
    lista_usuarios,
    format_func=_fmt_contato,
    index=_default_index,
    key="sel_contato_final_v2",
)

if not contato:
    st.info("Selecione um contato pra iniciar a conversa.")
    st.stop()


# ── MARCADOR "novas mensagens" estilo WhatsApp ─────────────
# Captura os IDs que ESTAVAM não-lidos no momento que o usuário entrou
# nesta conversa. `_render_chat_messages` usa isso pra inserir um separador
# "⬇ N nova(s) mensagem(ns)" acima da primeira mensagem nova.
#
# Sem falso positivo:
#  - Quando o usuário PERMANECE na conversa e chega nova msg pelo fragmento,
#    `_ids_novas` em session_state NÃO é re-capturado (a nova msg fica
#    abaixo do separador, como esperado).
#  - Quando ele TROCA de contato e volta, recapturamos — como tudo já foi
#    marcado lido, `_ids_novas` fica vazio e o separador não aparece.
_chave_nl = "_chat_marcador_novas"
_cur_marc = st.session_state.get(_chave_nl)
if _cur_marc is None or _cur_marc[0] != contato:
    _conn_nl = db.conectar()
    _c_nl = _conn_nl.cursor()
    try:
        _c_nl.execute(
            "SELECT id FROM chat "
            "WHERE remetente = %s AND destinatario = %s "
            "AND lido_em IS NULL",
            (contato, usuario),
        )
        _ids_novas = {int(r[0]) for r in _c_nl.fetchall()}
    finally:
        _conn_nl.close()
    st.session_state[_chave_nl] = (contato, _ids_novas)

# Marca como lidas todas as mensagens recebidas desse contato
db.marcar_lidas(usuario, contato)
# Render do painel de mensagens (auto-refresh 2s via fragmento)
_render_chat_messages(usuario, contato)

# Campo de Envio (fora do fragmento; submete a página).
# Layout: text_area baixo (uma linha) + botão "➤" do mesmo tamanho ao lado.
st.markdown(
    """
    <style>
    /* Form do chat: borda fina, sem padding interno gordo */
    div[data-testid="stForm"].chat-send-form,
    form.chat-send-form {
        padding: 8px !important;
    }
    /* Botão Enviar: mesma altura do textarea, fonte grande no ➤, centralizado. */
    .chat-send-form div[data-testid="stFormSubmitButton"] button {
        font-size: 1.5rem !important;
        font-weight: 600 !important;
        height: 68px !important;
        padding: 0 !important;
        line-height: 1 !important;
        display: flex; align-items: center; justify-content: center;
    }
    /* Reduz padding interno do textarea (default é gordo demais aqui). */
    .chat-send-form textarea {
        min-height: 68px !important;
        padding: 10px 12px !important;
    }
    </style>
    """,
    unsafe_allow_html=True,
)
with st.form("f_chat_v3_final", clear_on_submit=True, border=False):
    # Wrapper pra escopar o CSS via classe própria. Streamlit não deixa passar
    # `className` em st.form — workaround é wrapping via st.markdown anchor.
    st.markdown("<div class='chat-send-form'>", unsafe_allow_html=True)
    in_c1, in_c2 = st.columns([6, 1], gap="small")
    msg_input = in_c1.text_area(
        "Digite uma mensagem...",
        height=68,
        label_visibility="collapsed",
        placeholder="Digite uma mensagem...",
    )
    _enviar = in_c2.form_submit_button(
        "➤", use_container_width=True, help="Enviar mensagem",
    )
    st.markdown("</div>", unsafe_allow_html=True)
    if _enviar and msg_input.strip():
        # Grava timestamp completo "DD/MM/YYYY HH:MM" pra suporte ao
        # separador de dias no histórico.
        conn = db.conectar()
        c = conn.cursor()
        _agora_iso = datetime.now().strftime("%d/%m/%Y %H:%M")
        c.execute(
            "INSERT INTO chat (remetente, destinatario, mensagem, data) "
            "VALUES (%s,%s,%s,%s)",
            (usuario, contato, msg_input.strip(), _agora_iso),
        )
        conn.commit()
        conn.close()
        # Garante que o selectbox abra NA conversa atual mesmo se o
        # fragmento global tiver mudado o hint enquanto o user digitava.
        # `_chat_force_target` tem precedência absoluta.
        st.session_state["_chat_force_target"] = contato
        st.rerun()

import streamlit as st
import database as db


def validar_login(usuario, senha):
    """Valida o par (usuario, senha) e popula a session_state se OK.

    Mudou em maio/2026: como bcrypt usa salt aleatório, NÃO dá pra comparar
    hash via SQL (`WHERE senha = ?`) — agora busca o hash do usuário e
    verifica com `db.verificar_hash`. Aceita SHA-256 legado e re-grava como
    bcrypt no primeiro login bem-sucedido (migração transparente).
    """
    if not usuario or senha is None:
        return False

    conn = db.conectar()
    c = conn.cursor()
    try:
        c.execute(
            "SELECT nome, perfil, senha FROM usuarios WHERE nome = %s",
            (usuario,),
        )
        row = c.fetchone()
    finally:
        conn.close()

    if not row:
        return False
    nome_db, perfil_db, hash_db = row

    valido, precisa_rehash = db.verificar_hash(senha, hash_db)
    if not valido:
        return False

    # Migração transparente: usuário com hash SHA-256 legado → re-grava bcrypt.
    if precisa_rehash:
        try:
            db.atualizar_hash_senha(nome_db, senha)
        except Exception:
            pass  # rehash falhou — não bloqueia o login

    # Trava o login no navegador (impede deslogar ao atualizar)
    st.session_state.autenticado = True
    st.session_state.usuario = nome_db
    st.session_state.perfil = perfil_db
    return True


def logout():
    st.session_state.autenticado = False
    st.session_state.usuario = None
    st.session_state.perfil = None
    st.rerun()
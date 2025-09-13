from uuid import UUID, uuid4
from datetime import datetime
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, EmailStr, Field

app = FastAPI(title="Usuarios API", version="1.0.0")

# ========= Modelos =========
username_regex = r"^[a-zA-Z0-9._-]{3,30}$"

class UserBase(BaseModel):
    email: EmailStr
    username: str = Field(..., pattern=username_regex)  
    full_name: Optional[str] = None
    is_active: bool = True

class UserCreate(UserBase):
    """Crea usuario sin id"""
    pass

class UserUpdate(BaseModel):
    """Actualiza usuario"""
    email: Optional[EmailStr] = None
    username: Optional[str] = Field(None, pattern=username_regex)  
    full_name: Optional[str] = None
    is_active: Optional[bool] = None

class User(UserBase):
    """Modelo de respuesta."""
    id: UUID = Field(default_factory=uuid4)
    created_at: datetime = Field(default_factory=datetime.utcnow)

# "Base de datos" en memoria
db: dict[UUID, User] = {}

# ========= Utilidades =========
def _ensure_unique(email: str, username: str, exclude_id: Optional[UUID] = None):
    e_low = email.lower()
    u_low = username.lower()
    for uid, u in db.items():
        if exclude_id is not None and uid == exclude_id:
            continue
        if u.email.lower() == e_low:
            raise HTTPException(status_code=409, detail="Email ya está en uso")
        if u.username.lower() == u_low:
            raise HTTPException(status_code=409, detail="Username ya está en uso")

def _apply_updates(u: User, data: UserUpdate) -> User:
    updated = u.model_copy()
    if data.email is not None:
        updated.email = data.email
    if data.username is not None:
        updated.username = data.username
    if data.full_name is not None:
        updated.full_name = data.full_name
    if data.is_active is not None:
        updated.is_active = data.is_active
    return updated

# ========= Endpoints =========


@app.get("/users", response_model=list[User])
def list_users(q: Optional[str] = None, limit: int = 50, offset: int = 0):
    """
    Lista usuarios, con búsqueda simple (en email, username y nombre).
    Soporta paginación por limit/offset.
    """
    users = list(db.values())
    if q:
        q_low = q.lower()
        users = [
            u for u in users
            if q_low in u.email.lower()
            or q_low in u.username.lower()
            or (u.full_name or "").lower().find(q_low) >= 0
        ]
    return users[offset : offset + limit]

@app.get("/users/{user_id}", response_model=User)
def get_user(user_id: UUID):
    user = db.get(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    return user

@app.post("/users", status_code=201, response_model=User)
def create_user(data: UserCreate):
    _ensure_unique(data.email, data.username)
    user = User(**data.model_dump())
    db[user.id] = user
    return user

@app.put("/users/{user_id}", response_model=User)
def replace_user(user_id: UUID, data: UserCreate):
    if user_id not in db:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    _ensure_unique(data.email, data.username, exclude_id=user_id)
    current = db[user_id]
    replaced = User(
        id=current.id,
        created_at=current.created_at,
        **data.model_dump(),
    )
    db[user_id] = replaced
    return replaced

@app.patch("/users/{user_id}", response_model=User)
def update_user(user_id: UUID, data: UserUpdate):
    user = db.get(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")

    new_email = data.email if data.email is not None else user.email
    new_username = data.username if data.username is not None else user.username
    _ensure_unique(new_email, new_username, exclude_id=user_id)

    updated = _apply_updates(user, data)
    db[user_id] = updated
    return updated

@app.delete("/users/{user_id}", status_code=204)
def delete_user(user_id: UUID):
    if user_id not in db:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    del db[user_id]
    return None

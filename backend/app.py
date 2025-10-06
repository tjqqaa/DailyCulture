# app.py
import os
from uuid import uuid4
from datetime import datetime, timedelta
from typing import Optional, List, Literal, Tuple

from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr, Field

from sqlalchemy import (
    create_engine, String, DateTime, Boolean, select, func, or_,
    UniqueConstraint, ForeignKey, Integer, update, event
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, Session, sessionmaker
from sqlalchemy.exc import IntegrityError

from dotenv import load_dotenv

# Auth helpers
from passlib.context import CryptContext
from jose import jwt, JWTError

# --- carga env ---
load_dotenv()

# ========================== DB LOCAL ==========================
# Opción 1 (por defecto): SQLite local (archivo ./local.db)
# Opción 2: Postgres local -> exporta, por ejemplo:
#   DATABASE_URL=postgresql+psycopg2://postgres:postgres@localhost:5432/dailyculture
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./local.db")

is_sqlite = DATABASE_URL.startswith("sqlite")
connect_args = {"check_same_thread": False} if is_sqlite else {}

# Evitamos pasar pool_* cuando es SQLite (causa TypeError)
engine_kwargs = dict(
    echo=False,
    future=True,
    connect_args=connect_args,
)
if not is_sqlite:
    engine_kwargs.update(
        pool_pre_ping=True,
        pool_recycle=300,
    )

engine = create_engine(DATABASE_URL, **engine_kwargs)

# PRAGMA para que SQLite respete claves foráneas
if is_sqlite:
    @event.listens_for(engine, "connect")
    def _set_sqlite_pragma(dbapi_connection, connection_record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

SessionLocal = sessionmaker(engine, expire_on_commit=False, autoflush=False)

class Base(DeclarativeBase):
    pass


# --------------------------- MODELOS ORM ---------------------------
class UserORM(Base):
    __tablename__ = "users"
    __table_args__ = (UniqueConstraint("email"), UniqueConstraint("username"))
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    email: Mapped[str] = mapped_column(String(255), nullable=False)
    username: Mapped[str] = mapped_column(String(30), nullable=False)
    full_name: Mapped[Optional[str]] = mapped_column(String(255))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    password_hash: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)

class PointsORM(Base):
    __tablename__ = "points"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    total: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

class FriendORM(Base):
    __tablename__ = "friends"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    user_a_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    user_b_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    requested_by_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="pending", nullable=False)  # pending/accepted/declined/blocked
    pair_key: Mapped[str] = mapped_column(String(80), unique=True, nullable=False)      # min(a,b):max(a,b)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    responded_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)

# ¡Crea todo al final!
Base.metadata.create_all(engine)


# --------------------------- Pydantic ---------------------------
username_regex = r"^[a-zA-Z0-9._-]{3,30}$"

class UserBase(BaseModel):
    email: EmailStr
    username: str = Field(..., pattern=username_regex)
    full_name: Optional[str] = None
    is_active: bool = True

# SIN límite de 72: permitimos contraseñas largas (p.ej. hasta 256)
class UserCreate(UserBase):
    password: str = Field(..., min_length=8, max_length=256)

class UserUpdate(BaseModel):
    email: Optional[EmailStr] = None
    username: Optional[str] = Field(None, pattern=username_regex)
    full_name: Optional[str] = None
    is_active: Optional[bool] = None

class User(BaseModel):
    id: str
    email: EmailStr
    username: str
    full_name: Optional[str] = None
    is_active: bool
    created_at: datetime
    class Config:
        from_attributes = True

class LoginPayload(BaseModel):
    username: str
    password: str

class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: User

class PointsOut(BaseModel):
    user_id: str
    total: int
    updated_at: datetime
    class Config:
        from_attributes = True

class AddPointsPayload(BaseModel):
    amount: int = Field(..., ge=1, le=100000)

class Friend(BaseModel):
    id: str
    user_a_id: str
    user_b_id: str
    requested_by_id: str
    status: Literal["pending", "accepted", "declined", "blocked"]
    created_at: datetime
    responded_at: Optional[datetime] = None
    class Config:
        from_attributes = True

class FriendRequestCreate(BaseModel):
    to_user_id: Optional[str] = None
    to_username: Optional[str] = None

class LeaderItem(BaseModel):
    user_id: str
    username: str
    full_name: Optional[str] = None
    points: int


# --------------------------- Auth utils (PBKDF2) ---------------------------
# Usamos PBKDF2-SHA256 (sin límite de 72 bytes, puro Python)
pwd_context = CryptContext(
    schemes=["pbkdf2_sha256"],
    deprecated="auto",
    pbkdf2_sha256__default_rounds=480000,
)

SECRET_KEY = os.getenv("SECRET_KEY", "CHANGE-ME")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MIN = 60 * 24 * 7  # 7 días

def hash_password(pw: str) -> str:
    try:
        return pwd_context.hash(pw)
    except Exception as e:
        print("Password hashing failed:", repr(e))
        raise HTTPException(status_code=500, detail="Password hashing failed.")

def verify_password(pw: str, pw_hash: str) -> bool:
    try:
        return pwd_context.verify(pw, pw_hash)
    except Exception as e:
        print("Password verify failed:", repr(e))
        return False

def create_access_token(sub: str) -> str:
    payload = {"sub": sub, "exp": datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MIN)}
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


# --------------------------- FastAPI ---------------------------
app = FastAPI(title="DailyCulture API (local)", version="1.0.0")

# CORS para local dev (Flutter, web, etc.)
allowed = os.getenv("CORS_ORIGINS", "http://localhost, http://localhost:3000, http://127.0.0.1").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in allowed],
    allow_methods=["*"],
    allow_headers=["*"],
    allow_credentials=True,
)

security = HTTPBearer()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# --------------------------- Utilidades ---------------------------
def get_current_user(
    creds: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
) -> UserORM:
    token = creds.credentials
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id: str = payload.get("sub")
        if not user_id:
            raise HTTPException(status_code=401, detail="Token inválido")
    except JWTError:
        raise HTTPException(status_code=401, detail="Token inválido")
    user = db.get(UserORM, user_id)
    if not user:
        raise HTTPException(status_code=401, detail="Usuario no encontrado")
    return user

def _ensure_unique(db: Session, email: str, username: str, exclude_id: Optional[str] = None):
    q = select(UserORM).where(or_(func.lower(UserORM.email) == email.lower(),
                                  func.lower(UserORM.username) == username.lower()))
    for u in db.scalars(q).all():
        if exclude_id and u.id == exclude_id:
            continue
        if u.email.lower() == email.lower():
            raise HTTPException(status_code=409, detail="Email ya está en uso")
        if u.username.lower() == username.lower():
            raise HTTPException(status_code=409, detail="Username ya está en uso")

def _ensure_points_row(db: Session, user_id: str) -> PointsORM:
    row = db.get(PointsORM, user_id)
    if not row:
        row = PointsORM(user_id=user_id, total=0)
        db.add(row)
        db.commit()
        db.refresh(row)
    return row

def _add_points(db: Session, user_id: str, amount: int) -> PointsORM:
    if amount <= 0:
        raise HTTPException(status_code=400, detail="amount debe ser positivo")
    _ensure_points_row(db, user_id)
    db.execute(
        update(PointsORM)
        .where(PointsORM.user_id == user_id)
        .values(total=PointsORM.total + amount)
    )
    db.commit()
    return db.get(PointsORM, user_id)

def _pair_key(a: str, b: str) -> Tuple[str, str, str]:
    aa, bb = sorted([a, b])
    return aa, bb, f"{aa}:{bb}"

def _get_friendship(db: Session, me_id: str, other_id: str) -> Optional[FriendORM]:
    _, _, pk = _pair_key(me_id, other_id)
    stmt = select(FriendORM).where(FriendORM.pair_key == pk)
    return db.scalars(stmt).first()


# --------------------------- Rutas ---------------------------
@app.get("/")
def root():
    return {"service": "dailyculture-local", "docs": "/docs", "db": DATABASE_URL, "hash_scheme": "pbkdf2_sha256"}

@app.get("/health")
def health():
    import sys
    return {
        "python": sys.version,
        "db_url_scheme": DATABASE_URL.split("://", 1)[0],
        "sqlite": is_sqlite,
        "hash_scheme": "pbkdf2_sha256",
    }


# --------------------------- Users CRUD ---------------------------
@app.get("/users", response_model=List[User])
def list_users(q: Optional[str] = Query(None), limit: int = 50, offset: int = 0, db: Session = Depends(get_db)):
    stmt = select(UserORM).order_by(UserORM.created_at.desc())
    if q:
        like = f"%{q.lower()}%"
        stmt = stmt.where(
            or_(
                func.lower(UserORM.email).like(like),
                func.lower(UserORM.username).like(like),
                func.lower(func.coalesce(UserORM.full_name, "")).like(like),
            )
        )
    return [User.model_validate(u) for u in db.scalars(stmt.offset(offset).limit(limit)).all()]

@app.get("/users/{user_id}", response_model=User)
def get_user(user_id: str, db: Session = Depends(get_db)):
    u = db.get(UserORM, user_id)
    if not u:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    return User.model_validate(u)

@app.post("/users", status_code=201, response_model=User)
def create_user(data: UserCreate, db: Session = Depends(get_db)):
    _ensure_unique(db, data.email, data.username)
    try:
        u = UserORM(
            email=data.email,
            username=data.username,
            full_name=data.full_name,
            is_active=data.is_active,
            password_hash=hash_password(data.password),
        )
        db.add(u)
        db.commit()
        db.refresh(u)
        return User.model_validate(u)
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="Email o username ya existen (unique).")

@app.put("/users/{user_id}", response_model=User)
def replace_user(user_id: str, data: UserCreate, db: Session = Depends(get_db)):
    u = db.get(UserORM, user_id)
    if not u:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    _ensure_unique(db, data.email, data.username, exclude_id=user_id)
    try:
        u.email = data.email
        u.username = data.username
        u.full_name = data.full_name
        u.is_active = data.is_active
        u.password_hash = hash_password(data.password)
        db.commit()
        db.refresh(u)
        return User.model_validate(u)
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="Email o username ya existen (unique).")

@app.patch("/users/{user_id}", response_model=User)
def update_user(user_id: str, data: UserUpdate, db: Session = Depends(get_db)):
    u = db.get(UserORM, user_id)
    if not u:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    _ensure_unique(db, data.email or u.email, data.username or u.username, exclude_id=user_id)
    if data.email is not None:
        u.email = data.email
    if data.username is not None:
        u.username = data.username
    if data.full_name is not None:
        u.full_name = data.full_name
    if data.is_active is not None:
        u.is_active = data.is_active
    db.commit()
    db.refresh(u)
    return User.model_validate(u)

@app.delete("/users/{user_id}", status_code=204)
def delete_user(user_id: str, db: Session = Depends(get_db)):
    u = db.get(UserORM, user_id)
    if not u:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    db.delete(u)
    db.commit()
    return None


# --------------------------- Auth ---------------------------
@app.post("/auth/login", response_model=TokenResponse)
def auth_login(payload: LoginPayload, db: Session = Depends(get_db)):
    name = payload.username.strip().lower()
    stmt = select(UserORM).where(or_(func.lower(UserORM.username) == name, func.lower(UserORM.email) == name))
    user = db.scalars(stmt).first()
    if not user or not user.password_hash or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Credenciales inválidas")
    token = create_access_token(user.id)
    return TokenResponse(access_token=token, user=User.model_validate(user))

@app.get("/auth/me", response_model=User)
def auth_me(user: UserORM = Depends(get_current_user)):
    return User.model_validate(user)


# --------------------------- Puntos ---------------------------
@app.get("/points/me", response_model=PointsOut)
def get_my_points(user: UserORM = Depends(get_current_user), db: Session = Depends(get_db)):
    row = _ensure_points_row(db, user.id)
    return PointsOut.model_validate(row)

@app.post("/points/add", response_model=PointsOut)
def add_my_points(payload: AddPointsPayload, user: UserORM = Depends(get_current_user), db: Session = Depends(get_db)):
    row = _add_points(db, user.id, payload.amount)
    return PointsOut.model_validate(row)


# --------------------------- Amigos ---------------------------
@app.post("/friends/request", response_model=Friend, status_code=201)
def send_friend_request(payload: FriendRequestCreate, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    if not payload.to_user_id and not payload.to_username:
        raise HTTPException(status_code=400, detail="Debes enviar to_user_id o to_username")
    other = None
    if payload.to_user_id:
        other = db.get(UserORM, payload.to_user_id)
    elif payload.to_username:
        stmt = select(UserORM).where(func.lower(UserORM.username) == payload.to_username.strip().lower())
        other = db.scalars(stmt).first()
    if not other:
        raise HTTPException(status_code=404, detail="Usuario destino no encontrado")
    if other.id == me.id:
        raise HTTPException(status_code=400, detail="No puedes enviarte amistad a ti mismo")

    a, b, pk = _pair_key(me.id, other.id)
    existing = _get_friendship(db, me.id, other.id)
    if existing:
        if existing.status == "accepted":
            raise HTTPException(status_code=409, detail="Ya sois amigos")
        if existing.status == "pending":
            raise HTTPException(status_code=409, detail="Solicitud ya pendiente")
        existing.status = "pending"
        existing.requested_by_id = me.id
        existing.responded_at = None
        db.commit()
        db.refresh(existing)
        return Friend.model_validate(existing)

    fr = FriendORM(user_a_id=a, user_b_id=b, requested_by_id=me.id, status="pending", pair_key=pk)
    db.add(fr)
    db.commit()
    db.refresh(fr)
    return Friend.model_validate(fr)

@app.post("/friends/{other_user_id}/accept", response_model=Friend)
def accept_friend_request(other_user_id: str, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    fr = _get_friendship(db, me.id, other_user_id)
    if not fr:
        raise HTTPException(status_code=404, detail="Solicitud no encontrada")
    if fr.status != "pending" or fr.requested_by_id == me.id:
        raise HTTPException(status_code=400, detail="No puedes aceptar esta solicitud")
    fr.status = "accepted"
    fr.responded_at = datetime.utcnow()
    db.commit()
    db.refresh(fr)
    return Friend.model_validate(fr)

@app.post("/friends/{other_user_id}/decline", response_model=Friend)
def decline_friend_request(other_user_id: str, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    fr = _get_friendship(db, me.id, other_user_id)
    if not fr:
        raise HTTPException(status_code=404, detail="Solicitud no encontrada")
    if fr.status != "pending" or fr.requested_by_id == me.id:
        raise HTTPException(status_code=400, detail="No puedes rechazar esta solicitud")
    fr.status = "declined"
    fr.responded_at = datetime.utcnow()
    db.commit()
    db.refresh(fr)
    return Friend.model_validate(fr)

@app.delete("/friends/{other_user_id}", status_code=204)
def remove_friend(other_user_id: str, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    fr = _get_friendship(db, me.id, other_user_id)
    if not fr:
        return None
    db.delete(fr)
    db.commit()
    return None

@app.get("/friends", response_model=List[User])
def list_friends(db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    stmt = select(FriendORM).where(
        FriendORM.status == "accepted",
        or_(FriendORM.user_a_id == me.id, FriendORM.user_b_id == me.id),
    )
    rows = db.scalars(stmt).all()
    friend_ids = [(r.user_b_id if r.user_a_id == me.id else r.user_a_id) for r in rows]
    if not friend_ids:
        return []
    ustmt = select(UserORM).where(UserORM.id.in_(friend_ids))
    return [User.model_validate(u) for u in db.scalars(ustmt).all()]

@app.get("/friends/requests")
def list_friend_requests(db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    incoming_stmt = select(FriendORM).where(
        FriendORM.status == "pending",
        FriendORM.requested_by_id != me.id,
        or_(FriendORM.user_a_id == me.id, FriendORM.user_b_id == me.id),
    )
    outgoing_stmt = select(FriendORM).where(
        FriendORM.status == "pending",
        FriendORM.requested_by_id == me.id,
    )
    incoming = [Friend.model_validate(x) for x in db.scalars(incoming_stmt).all()]
    outgoing = [Friend.model_validate(x) for x in db.scalars(outgoing_stmt).all()]
    return {"incoming": incoming, "outgoing": outgoing}

@app.get("/points/leaderboard/friends", response_model=List[LeaderItem])
def friends_leaderboard(limit: int = 100, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    fstmt = select(FriendORM).where(
        FriendORM.status == "accepted",
        or_(FriendORM.user_a_id == me.id, FriendORM.user_b_id == me.id),
    )
    friends = db.scalars(fstmt).all()
    friend_ids = set((r.user_b_id if r.user_a_id == me.id else r.user_a_id) for r in friends)
    user_ids = list(friend_ids | {me.id})
    if not user_ids:
        user_ids = [me.id]
    stmt = (
        select(
            UserORM.id, UserORM.username, UserORM.full_name,
            func.coalesce(PointsORM.total, 0).label("points"),
        )
        .select_from(UserORM)
        .outerjoin(PointsORM, PointsORM.user_id == UserORM.id)
        .where(UserORM.id.in_(user_ids))
        .order_by(func.coalesce(PointsORM.total, 0).desc(), UserORM.username.asc())
        .limit(limit)
    )
    rows = db.execute(stmt).all()
    return [
        LeaderItem(user_id=row[0], username=row[1], full_name=row[2], points=int(row[3] or 0))
        for row in rows
    ]

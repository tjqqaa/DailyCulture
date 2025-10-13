# app.py
import os
from uuid import uuid4
from datetime import datetime, timedelta, date
from typing import Optional, List, Literal, Tuple

from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr, Field

from sqlalchemy import (
    create_engine, String, DateTime, Date, Boolean, Float, Integer,
    select, func, or_, and_, update, event, UniqueConstraint, ForeignKey,
    literal,  # <-- necesario para COALESCE con 0
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
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./local.db")

is_sqlite = DATABASE_URL.startswith("sqlite")
connect_args = {"check_same_thread": False} if is_sqlite else {}

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

# --------- NUEVO: Actividades ----------
class ActivityORM(Base):
    __tablename__ = "activities"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False)

    title: Mapped[str] = mapped_column(String(200), nullable=False)
    kind: Mapped[str] = mapped_column(String(30), nullable=False, default="custom")  # visit/read/watch/custom/...
    notes: Mapped[Optional[str]] = mapped_column(String(1000))

    # enlace opcional (artículo, vídeo, etc.)
    url: Mapped[Optional[str]] = mapped_column(String(500))

    # lugar opcional para "visit"
    place_name: Mapped[Optional[str]] = mapped_column(String(200))
    place_lat: Mapped[Optional[float]] = mapped_column(Float)
    place_lon: Mapped[Optional[float]] = mapped_column(Float)
    radius_m: Mapped[int] = mapped_column(Integer, nullable=False, default=150)

    # fecha objetivo (para mostrar en "Hoy")
    due_date: Mapped[Optional[date]] = mapped_column(Date, index=True)

    # puntos a dar al completar
    points_on_complete: Mapped[int] = mapped_column(Integer, nullable=False, default=5)

    # estado
    is_done: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    done_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)


# --------------------------- Pydantic ---------------------------
username_regex = r"^[a-zA-Z0-9._-]{3,30}$"

class UserBase(BaseModel):
    email: EmailStr
    username: str = Field(..., pattern=username_regex)
    full_name: Optional[str] = None
    is_active: bool = True

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

# --------- NUEVO: Esquemas de actividades ----------
class ActivityBase(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)
    kind: str = Field("custom", max_length=30)   # visit/read/watch/custom/...
    notes: Optional[str] = Field(None, max_length=1000)
    url: Optional[str] = Field(None, max_length=500)
    place_name: Optional[str] = Field(None, max_length=200)
    place_lat: Optional[float] = None
    place_lon: Optional[float] = None
    radius_m: Optional[int] = Field(150, ge=25, le=5000)
    due_date: Optional[date] = None
    points_on_complete: Optional[int] = Field(5, ge=0, le=100000)

class ActivityCreate(ActivityBase):
    pass

class ActivityUpdate(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=200)
    kind: Optional[str] = Field(None, max_length=30)
    notes: Optional[str] = Field(None, max_length=1000)
    url: Optional[str] = Field(None, max_length=500)
    place_name: Optional[str] = Field(None, max_length=200)
    place_lat: Optional[float] = None
    place_lon: Optional[float] = None
    radius_m: Optional[int] = Field(None, ge=25, le=5000)
    due_date: Optional[date] = None
    points_on_complete: Optional[int] = Field(None, ge=0, le=100000)
    is_done: Optional[bool] = None  # permitir marcar/desmarcar

class ActivityOut(ActivityBase):
    id: str
    user_id: str
    is_done: bool
    done_at: Optional[datetime]
    created_at: datetime
    updated_at: datetime
    class Config:
        from_attributes = True

class CheckinPayload(BaseModel):
    lat: float
    lon: float

class CompletePayload(BaseModel):
    lat: Optional[float] = None
    lon: Optional[float] = None
    verify_location: bool = True     # si la actividad tiene lugar, exigir lat/lon y estar dentro del radio
    points: Optional[int] = None     # si lo pasas, sobreescribe points_on_complete para esta finalización


# --------------------------- Auth utils (PBKDF2) ---------------------------
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
app = FastAPI(title="DailyCulture API (local)", version="1.1.0")

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

# Haversine (metros)
from math import asin, cos, sqrt
def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p = 0.017453292519943295
    a = 0.5 - cos((lat2 - lat1) * p) / 2 + cos(lat1 * p) * cos(lat2 * p) * (1 - cos((lon2 - lon1) * p)) / 2
    return 12742000 * asin(sqrt(a))


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

        # crear fila de puntos al vuelo
        _ensure_points_row(db, u.id)

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

# >>> NUEVO: leaderboard con amigos (incluye al propio usuario)
@app.get("/points/leaderboard/friends", response_model=List[LeaderItem])
def friends_leaderboard(
    limit: int = 100,
    include_me: bool = True,
    db: Session = Depends(get_db),
    me: UserORM = Depends(get_current_user),
):
    ids = set()
    if include_me:
        ids.add(me.id)

    stmt_f = select(FriendORM).where(
        FriendORM.status == "accepted",
        or_(FriendORM.user_a_id == me.id, FriendORM.user_b_id == me.id),
    )
    for fr in db.scalars(stmt_f).all():
        other = fr.user_b_id if fr.user_a_id == me.id else fr.user_a_id
        ids.add(other)

    if not ids:
        row = _ensure_points_row(db, me.id)
        return [LeaderItem(user_id=me.id, username=me.username, full_name=me.full_name, points=row.total)]

    for uid in ids:
        _ensure_points_row(db, uid)

    stmt = (
        select(
            UserORM.id,
            UserORM.username,
            UserORM.full_name,
            func.coalesce(PointsORM.total, literal(0)).label("points"),
        )
        .join(PointsORM, PointsORM.user_id == UserORM.id, isouter=True)
        .where(UserORM.id.in_(ids))
        .order_by(func.coalesce(PointsORM.total, 0).desc(), UserORM.username.asc())
        .limit(limit)
    )

    rows = db.execute(stmt).all()
    return [
        LeaderItem(user_id=uid, username=uname, full_name=fname, points=int(pts or 0))
        for uid, uname, fname, pts in rows
    ]


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
        raise HTTPException(status_code=400, detail="No puedes enviarte amistad a ti mismo")  # fix

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


# --------------------------- NUEVO: Actividades ---------------------------
def _owner_activity(db: Session, me_id: str, activity_id: str) -> ActivityORM:
    a = db.get(ActivityORM, activity_id)
    if not a or a.user_id != me_id:
        raise HTTPException(status_code=404, detail="Actividad no encontrada")
    return a

@app.post("/activities", response_model=ActivityOut, status_code=201)
def create_activity(payload: ActivityCreate, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    a = ActivityORM(
        user_id=me.id,
        title=payload.title,
        kind=payload.kind or "custom",
        notes=payload.notes,
        url=payload.url,
        place_name=payload.place_name,
        place_lat=payload.place_lat,
        place_lon=payload.place_lon,
        radius_m=payload.radius_m or 150,
        due_date=payload.due_date,
        points_on_complete=payload.points_on_complete or 5,
    )
    db.add(a)
    db.commit()
    db.refresh(a)
    return ActivityOut.model_validate(a)

@app.get("/activities", response_model=List[ActivityOut])
def list_activities(
    status: Literal["pending", "done", "all"] = "all",
    date_filter: Optional[Literal["today", "overdue"]] = Query(None, alias="date"),
    due_from: Optional[date] = None,
    due_to: Optional[date] = None,
    limit: int = 100,
    offset: int = 0,
    db: Session = Depends(get_db),
    me: UserORM = Depends(get_current_user),
):
    stmt = select(ActivityORM).where(ActivityORM.user_id == me.id)

    if status == "pending":
        stmt = stmt.where(ActivityORM.is_done.is_(False))
    elif status == "done":
        stmt = stmt.where(ActivityORM.is_done.is_(True))

    today = date.today()
    if date_filter == "today":
        stmt = stmt.where(ActivityORM.due_date == today)
    elif date_filter == "overdue":
        stmt = stmt.where(and_(ActivityORM.is_done.is_(False), ActivityORM.due_date != None, ActivityORM.due_date < today))  # noqa: E711

    if due_from is not None:
        stmt = stmt.where(ActivityORM.due_date >= due_from)
    if due_to is not None:
        stmt = stmt.where(ActivityORM.due_date <= due_to)

    stmt = stmt.order_by(
        ActivityORM.is_done.asc(),
        ActivityORM.due_date.is_(None),   # None al final
        ActivityORM.due_date.asc(),
        ActivityORM.created_at.desc(),
    ).offset(offset).limit(limit)

    rows = db.scalars(stmt).all()
    return [ActivityOut.model_validate(x) for x in rows]

@app.get("/activities/today", response_model=List[ActivityOut])
def list_today(db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    t = date.today()
    stmt = select(ActivityORM).where(ActivityORM.user_id == me.id, ActivityORM.due_date == t).order_by(ActivityORM.created_at.desc())
    rows = db.scalars(stmt).all()
    return [ActivityOut.model_validate(x) for x in rows]

@app.get("/activities/{activity_id}", response_model=ActivityOut)
def get_activity(activity_id: str, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    a = _owner_activity(db, me.id, activity_id)
    return ActivityOut.model_validate(a)

@app.patch("/activities/{activity_id}", response_model=ActivityOut)
def update_activity(activity_id: str, payload: ActivityUpdate, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    a = _owner_activity(db, me.id, activity_id)

    if payload.title is not None: a.title = payload.title
    if payload.kind is not None: a.kind = payload.kind
    if payload.notes is not None: a.notes = payload.notes
    if payload.url is not None: a.url = payload.url
    if payload.place_name is not None: a.place_name = payload.place_name
    if payload.place_lat is not None: a.place_lat = payload.place_lat
    if payload.place_lon is not None: a.place_lon = payload.place_lon
    if payload.radius_m is not None: a.radius_m = payload.radius_m
    if payload.due_date is not None: a.due_date = payload.due_date
    if payload.points_on_complete is not None: a.points_on_complete = payload.points_on_complete

    if payload.is_done is not None:
        a.is_done = payload.is_done
        a.done_at = datetime.utcnow() if a.is_done else None

    db.commit()
    db.refresh(a)
    return ActivityOut.model_validate(a)

@app.delete("/activities/{activity_id}", status_code=204)
def delete_activity(activity_id: str, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    a = _owner_activity(db, me.id, activity_id)
    db.delete(a)
    db.commit()
    return None

@app.post("/activities/{activity_id}/checkin")
def checkin_activity(activity_id: str, payload: CheckinPayload, db: Session = Depends(get_db), me: UserORM = Depends(get_current_user)):
    a = _owner_activity(db, me.id, activity_id)
    if a.place_lat is None or a.place_lon is None:
        raise HTTPException(status_code=400, detail="La actividad no tiene ubicación")
    dist = _haversine_m(payload.lat, payload.lon, a.place_lat, a.place_lon)
    inside = dist <= float(a.radius_m or 150)
    return {"activity_id": a.id, "distance_m": round(dist, 2), "inside": inside, "radius_m": a.radius_m}

@app.post("/activities/{activity_id}/complete", response_model=ActivityOut)
def complete_activity(
    activity_id: str,
    payload: CompletePayload = Depends(),
    db: Session = Depends(get_db),
    me: UserORM = Depends(get_current_user)
):
    a = _owner_activity(db, me.id, activity_id)
    if a.is_done:
        return ActivityOut.model_validate(a)

    # verificación opcional de ubicación
    if payload.verify_location and a.place_lat is not None and a.place_lon is not None:
        if payload.lat is None or payload.lon is None:
            raise HTTPException(status_code=400, detail="Debes enviar lat/lon para verificar esta actividad")
        dist = _haversine_m(payload.lat, payload.lon, a.place_lat, a.place_lon)
        if dist > float(a.radius_m or 150):
            raise HTTPException(status_code=403, detail=f"Fuera de zona ({int(dist)} m)")

    # marcar como hecha
    a.is_done = True
    a.done_at = datetime.utcnow()
    db.commit()
    db.refresh(a)

    # puntos
    pts = payload.points if payload.points is not None else (a.points_on_complete or 0)
    if pts > 0:
        _add_points(db, me.id, pts)

    return ActivityOut.model_validate(a)


# --------------------------- Crear tablas (AL FINAL) ---------------------------
Base.metadata.create_all(engine)

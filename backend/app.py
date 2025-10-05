import os
from uuid import uuid4
from datetime import datetime, timedelta
from typing import Optional, List

from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr, Field

from sqlalchemy import (
    create_engine, String, DateTime, Boolean, select, func, or_,
    UniqueConstraint, ForeignKey, Integer, update
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, Session, sessionmaker
from sqlalchemy.exc import IntegrityError

from dotenv import load_dotenv

# Auth helpers
from passlib.context import CryptContext
from jose import jwt, JWTError

# --- carga env
load_dotenv()

# --- DB
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./local.db")
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(
    DATABASE_URL,
    echo=False,
    future=True,
    connect_args=connect_args,
    pool_pre_ping=True,
    pool_recycle=300,
)
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
    # Permite NULL para filas antiguas; para nuevas siempre se rellena
    password_hash: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)


# Tabla simple de puntos acumulados (1:1 con users)
class PointsORM(Base):
    __tablename__ = "points"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    total: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


# ¡OJO! crea tablas DESPUÉS de declarar todos los modelos
Base.metadata.create_all(engine)


# --------------------------- Pydantic ---------------------------

username_regex = r"^[a-zA-Z0-9._-]{3,30}$"

class UserBase(BaseModel):
    email: EmailStr
    username: str = Field(..., pattern=username_regex)
    full_name: Optional[str] = None
    is_active: bool = True

class UserCreate(UserBase):
    password: str = Field(..., min_length=8)

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

# Puntos
class PointsOut(BaseModel):
    user_id: str
    total: int
    updated_at: datetime
    class Config:
        from_attributes = True

class AddPointsPayload(BaseModel):
    amount: int = Field(..., ge=1, le=100000)  # solo sumamos (>=1)


# --------------------------- Auth utils ---------------------------

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
SECRET_KEY = os.getenv("SECRET_KEY", "CHANGE-ME")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MIN = 60 * 24 * 7  # 7 días

def hash_password(pw: str) -> str:
    try:
        return pwd_context.hash(pw)
    except Exception as e:
        print("Password hashing failed:", repr(e))
        raise HTTPException(status_code=500, detail="Password hashing failed (bcrypt backend missing).")

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

app = FastAPI(title="DailyCulture API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
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


# --------------------------- Rutas básicas ---------------------------

@app.get("/")
def root():
    return {"service": "dailyculture", "docs": "/docs"}

# Health checks útiles en Azure
@app.get("/health")
def health():
    import sys
    try:
        import bcrypt  # type: ignore
        bcrypt_ver = getattr(bcrypt, "__version__", "unknown")
    except Exception as e:
        bcrypt_ver = f"ERROR: {e!r}"
    return {
        "python": sys.version,
        "db_url_scheme": DATABASE_URL.split("://", 1)[0],
        "bcrypt": bcrypt_ver,
        "passlib_has_bcrypt": "bcrypt" in pwd_context.schemes(),
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

# Devuelve el usuario autenticado (útil para tu ProfileView)
@app.get("/auth/me", response_model=User)
def auth_me(user: UserORM = Depends(get_current_user)):
    return User.model_validate(user)


# --------------------------- Puntos simples ---------------------------

@app.get("/points/me", response_model=PointsOut)
def get_my_points(
    user: UserORM = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    row = _ensure_points_row(db, user.id)
    return PointsOut.model_validate(row)

@app.post("/points/add", response_model=PointsOut)
def add_my_points(
    payload: AddPointsPayload,
    user: UserORM = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    row = _add_points(db, user.id, payload.amount)
    return PointsOut.model_validate(row)

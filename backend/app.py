import os
from uuid import uuid4
from datetime import datetime
from typing import Optional, List

from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr, Field

from sqlalchemy import (
    create_engine, String, DateTime, Boolean, select,
    func, or_, UniqueConstraint
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, Session, sessionmaker

from dotenv import load_dotenv

load_dotenv()  

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


class UserORM(Base):
    __tablename__ = "users"
    __table_args__ = (UniqueConstraint("email"), UniqueConstraint("username"))

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    email: Mapped[str] = mapped_column(String(255), nullable=False)
    username: Mapped[str] = mapped_column(String(30), nullable=False)
    full_name: Mapped[Optional[str]] = mapped_column(String(255))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


Base.metadata.create_all(engine)

username_regex = r"^[a-zA-Z0-9._-]{3,30}$"


class UserBase(BaseModel):
    email: EmailStr
    username: str = Field(..., pattern=username_regex)
    full_name: Optional[str] = None
    is_active: bool = True


class UserCreate(UserBase):
    pass


class UserUpdate(BaseModel):
    email: Optional[EmailStr] = None
    username: Optional[str] = Field(None, pattern=username_regex)
    full_name: Optional[str] = None
    is_active: Optional[bool] = None


class User(UserBase):
    id: str
    created_at: datetime

    class Config:
        from_attributes = True  


app = FastAPI(title="DailyCulture API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],          
    allow_methods=["*"],
    allow_headers=["*"],
    allow_credentials=True,
)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@app.get("/")
def root():
    return {"service": "dailyculture", "docs": "/docs"}




def _ensure_unique(db: Session, email: str, username: str, exclude_id: Optional[str] = None):
    q = select(UserORM).where(or_(UserORM.email.ilike(email), UserORM.username.ilike(username)))
    for u in db.scalars(q).all():
        if exclude_id and u.id == exclude_id:
            continue
        if u.email.lower() == email.lower():
            raise HTTPException(status_code=409, detail="Email ya está en uso")
        if u.username.lower() == username.lower():
            raise HTTPException(status_code=409, detail="Username ya está en uso")


@app.get("/users", response_model=List[User])
def list_users(
    q: Optional[str] = Query(None),
    limit: int = 50,
    offset: int = 0,
    db: Session = Depends(get_db),
):
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
    users = db.scalars(stmt.offset(offset).limit(limit)).all()
    return [User.model_validate(u) for u in users]


@app.get("/users/{user_id}", response_model=User)
def get_user(user_id: str, db: Session = Depends(get_db)):
    u = db.get(UserORM, user_id)
    if not u:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    return User.model_validate(u)


@app.post("/users", status_code=201, response_model=User)
def create_user(data: UserCreate, db: Session = Depends(get_db)):
    _ensure_unique(db, data.email, data.username)
    u = UserORM(**data.model_dump())
    db.add(u)
    db.commit()
    db.refresh(u)
    return User.model_validate(u)


@app.put("/users/{user_id}", response_model=User)
def replace_user(user_id: str, data: UserCreate, db: Session = Depends(get_db)):
    u = db.get(UserORM, user_id)
    if not u:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    _ensure_unique(db, data.email, data.username, exclude_id=user_id)

    u.email = data.email
    u.username = data.username
    u.full_name = data.full_name
    u.is_active = data.is_active

    db.commit()
    db.refresh(u)
    return User.model_validate(u)


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


# --- Ejecución local ---
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="127.0.0.1", port=8000, reload=True)

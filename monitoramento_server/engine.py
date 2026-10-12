from sqlalchemy import create_engine, String, ForeignKey, Integer, DateTime, Column
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker
engine = create_engine("sqlite:///BackupsDB", echo=True)

class Base(DeclarativeBase):
    pass

class Registers(Base):
    __teblename__ = "Metadados_backups"
    id = Column(Integer, primary_key=True)
    StartingDate = Column(String)
    DefiniedDate = Column(String)
    BackupDate = Column(String)
    
Session = sessionmaker(bind=engine)
session = Session()

novo = Registers()
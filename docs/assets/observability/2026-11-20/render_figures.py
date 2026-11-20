"""Rebuild original documentation figures (Pillow; no router dependencies)."""
from html import escape
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent
FONT = Path('C:/Windows/Fonts/segoeui.ttf')
BOLD = Path('C:/Windows/Fonts/segoeuib.ttf')
BG, INK, MUTED = '#f3f6fb', '#14243b', '#52627a'
BLUE, GREEN, RED, AMBER, GREY = '#2463b8', '#16816e', '#c13c4d', '#a2650b', '#778497'


class Figure:
    def __init__(self, name, title, subtitle, height=850):
        self.name, self.w, self.h = name, 1460, height
        self.im = Image.new('RGB', (self.w * 2, self.h * 2), BG)
        self.d = ImageDraw.Draw(self.im)
        self.svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" role="img">',
                    f'<title>{escape(title)}</title>', f'<desc>{escape(subtitle)}</desc>',
                    f'<rect width="100%" height="100%" fill="{BG}"/>']
        self.text(42, 28, 'CUDY HOME GATEWAY · ПРОЕКТ ДЛЯ ОБСУЖДЕНИЯ · 20.11.2026', 17, BLUE, True)
        self.text(42, 65, title, 37, INK, True)
        self.text(42, 119, subtitle, 20, MUTED)

    def box(self, x, y, w, h, color='white', border='#d8e0eb', radius=17):
        self.d.rounded_rectangle((x*2, y*2, (x+w)*2, (y+h)*2), radius=radius*2,
                                 fill=color, outline=border, width=2)
        self.svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{color}" stroke="{border}"/>')

    def text(self, x, y, text, size=23, color=INK, bold=False, width=None):
        font = ImageFont.truetype(str(BOLD if bold else FONT), size*2)
        lines = []
        for paragraph in text.split('\n'):
            current = ''
            for word in paragraph.split(' '):
                trial = (current+' '+word).strip()
                if width and self.d.textlength(trial, font=font) > width*2 and current:
                    lines.append(current); current = word
                else:
                    current = trial
            lines.append(current)
        for i, line in enumerate(lines):
            yy = y + i*(size+9)
            assert yy + size + 9 <= self.h, (self.name, line, yy)
            assert x + self.d.textlength(line, font=font)/2 < self.w-20, (self.name, line)
            self.d.text((x*2, yy*2), line, font=font, fill=color, stroke_width=0)
            self.svg.append(f'<text x="{x}" y="{yy+size}" font-family="Segoe UI,Arial,sans-serif" font-size="{size}" font-weight="{700 if bold else 400}" fill="{color}">{escape(line)}</text>')
        return y + len(lines)*(size+9)

    def arrow(self, points, color=BLUE):
        self.d.line([(x*2,y*2) for x,y in points], fill=color, width=5)
        self.svg.append(f'<polyline points="{" ".join(f"{x},{y}" for x,y in points)}" fill="none" stroke="{color}" stroke-width="2.5"/>')
        (a,b),(x,y) = points[-2:]
        if x != a:
            dx = 1 if x > a else -1
            tip = [(x,y),(x-10*dx,y-6),(x-10*dx,y+6)]
        else:
            dy = 1 if y > b else -1
            tip = [(x,y),(x-6,y-10*dy),(x+6,y-10*dy)]
        self.d.polygon([(a*2,b*2) for a,b in tip], fill=color)
        self.svg.append(f'<polygon points="{" ".join(f"{a},{b}" for a,b in tip)}" fill="{color}"/>')

    def finish(self):
        self.svg.append('</svg>')
        (OUT/(self.name+'.svg')).write_text('\n'.join(self.svg)+'\n', encoding='utf-8')
        self.im.save(OUT/(self.name+'.png'), optimize=True)


def architecture():
    f = Figure('architecture', 'Один набор фактов — статус, инциденты и история',
               'Целевая логическая схема. Разделение задач не означает добавление новых служб.', 920)
    f.box(40, 180, 330, 560)
    f.text(62, 204, 'Наблюдения', 29, bold=True)
    for y, title, body in [(280,'WAN и выход','Разные направления и цели'),
                            (420,'DNS роутера / REDMI','Профиль и порт определены'),
                            (560,'Процессы и правила','Локальные признаки состояния')]:
        f.box(60,y,290,112,'#edf3fc')
        f.text(77,y+14,title,23,BLUE,True,width=255)
        f.text(77,y+53,body,20,MUTED,width=255)
    f.box(435, 180, 395, 225)
    f.text(457,203,'Единый снимок',29,bold=True)
    f.text(457,258,'Область проверки · sample_id\nРезультат и причина\nВремя, boot_id и свежесть',22,width=350)
    f.box(435, 500, 395, 240)
    f.text(457,521,'Инциденты',29,bold=True)
    f.text(457,575,'Подозрение → подтверждение\n3 плохих / 2 хороших измерения\nUNKNOWN не означает recovery\nСвязанные проблемы учитываются',21,width=350)
    f.box(900,180,515,175,'#e6f3ef',GREEN)
    f.text(924,200,'История и пропуски',28,GREEN,True)
    f.text(924,252,'RAM + ограниченные сохранения\nДоступность рядом с покрытием\nНезависима от очистки очереди',21,width=460)
    f.box(900,460,515,185,'#fff3df',AMBER)
    f.text(924,480,'Очередь уведомлений',28,AMBER,True)
    f.text(924,532,'Событие сохранено до отправки\nMute и группировка влияют на доставку\nПодтверждение Telegram → receipt',21,width=460)
    f.box(900,735,515,115,'#eaf0ff',BLUE)
    f.text(924,750,'Telegram',27,BLUE,True)
    f.text(924,795,'Статус · диагностика · сводки',22,width=460)
    f.arrow([(370,292),(435,292)])
    f.arrow([(830,265),(900,265)],GREEN)
    f.arrow([(630,405),(630,500)])
    f.arrow([(830,555),(900,555)],AMBER)
    f.arrow([(1157,645),(1157,735)],AMBER)
    f.arrow([(830,350),(865,350),(865,790),(900,790)])
    f.text(42,795,'Всё хранится на роутере.',22,GREEN,True)
    f.text(42,833,'Полный обрыв: сообщение после восстановления.\nМаршрутизация не зависит от наблюдения.',20,MUTED,width=790)
    f.finish()


def samples():
    f = Figure('fresh-samples', 'Три чтения кэша — это не три проверки',
               'Синтетический пример. Интервалы показаны условно; это не обещание времени доставки.', 815)
    f.box(40,180,1375,190)
    f.text(62,197,'Повтор одного результата',26,bold=True)
    for x, label in [(70,'Чтение 1'),(440,'Чтение 2'),(810,'Чтение 3')]:
        f.box(x,250,280,90,'#eef1f6')
        f.text(x+17,260,label,22,bold=True)
        f.text(x+17,298,'sample_id = A · DOWN',21,MUTED)
    f.arrow([(350,295),(440,295)],GREY);f.arrow([(720,295),(810,295)],GREY)
    f.text(1120,254,'Один факт,\nодин голос.',23,BLUE,True,width=250)
    f.box(40,395,1375,235)
    f.text(62,413,'Новые измерения и отдельное подтверждение восстановления',25,bold=True)
    for i,(title,body,color,fill) in enumerate([
        ('A · DOWN','Подозрение 1/3',RED,'#fbecee'),('B · DOWN','Подозрение 2/3',RED,'#fbecee'),
        ('C · DOWN','Инцидент открыт',RED,'#fbecee'),('D · OK','Recovery 1/2',GREEN,'#e6f3ef'),
        ('E · OK','Восстановлен',GREEN,'#e6f3ef')]):
        x=65+i*270
        f.box(x,490,250,105,fill,color)
        f.text(x+14,505,title,24,color,True)
        f.text(x+14,548,body,20,MUTED)
    f.box(40,660,1375,110,'#e9edf3')
    f.text(62,678,'Нет свежего результата → UNKNOWN',25,GREY,True)
    f.text(62,720,'Не добавляет успех/ошибку, прерывает серию кандидата и не закрывает активный инцидент.',22,width=1320)
    f.finish()


def coverage():
    f = Figure('coverage', 'Доступность и покрытие наблюдением — разные числа',
               'Учебный пример за один час. Это не измерения установленного CUDY.', 735)
    f.box(40,185,1375,465)
    x,y,w=80,252,1290
    for share,color,label in [(0.7,GREEN,'42 мин: OK'),(0.1,RED,'6 мин:\nDOWN'),(0.2,GREY,'12 мин: нет данных')]:
        ww=w*share
        f.box(x,y,ww,100,color,color,0)
        f.text(x+12,y+34,label,20,'white',True,width=ww-20)
        x+=ww
    f.text(80,375,'Известно: 48 минут',22,bold=True)
    f.text(800,375,'Не наблюдалось: 12 минут',22,GREY,True)
    f.text(80,440,'87,5%',50,GREEN,True)
    f.text(80,512,'Доступность по наблюдениям\n42 / (42 + 6)',24,width=550)
    f.text(800,440,'80%',50,BLUE,True)
    f.text(800,512,'Покрытие периода\n(42 + 6) / 60',24,width=510)
    f.text(42,678,'Пробел не становится ни исправной связью, ни доказанным простоем. При отсутствии данных — «нет данных».',20,MUTED,width=1370)
    f.finish()


def telegram():
    f = Figure('telegram-concept', 'Telegram: кратко сейчас, подробнее по запросу',
               'КОНЦЕПТ, НЕ СКРИНШОТ БОТА. Все значения и времена ниже вымышлены.', 970)
    for x, title in [(40,'Главная'),(520,'После восстановления'),(1000,'История')]:
        f.box(x,185,420,705)
        f.box(x,185,420,64,'#e6eefb','#e6eefb')
        f.text(x+20,199,title,25,BLUE,True)
    f.text(62,278,'CUDY · свежесть данных',26,bold=True)
    f.text(62,334,'WAN: канал доступен\nMAIN: выход проверен\nDNS роутера: отвечает\nDNS REDMI: отвечает',23,width=375)
    f.text(62,495,'Интернет телефона:\nнет клиентской проверки',23,AMBER,True,width=375)
    f.text(62,593,'Последний запрос: 40 с назад\nАктивных инцидентов: 0',21,MUTED,width=375)
    for yy,label in [(697,'Обновить экран'),(755,'Проверить сейчас'),(813,'Инциденты · История')]:
        f.box(60,yy,380,44,'#edf3fc');f.text(76,yy+5,label,21,BLUE)
    f.text(542,278,'Связь восстановилась',25,GREEN,True,width=375)
    f.text(542,352,'Проблема замечена: 12:04\nВосстановление: 12:09\nДоставлено: 12:10',23,width=375)
    f.text(542,502,'Наблюдаемый сбой: ≈5 мин\nЗатронуты WAN, DNS и MAIN',22,width=375)
    f.text(542,628,'Сообщение отложено:\nво время сбоя Telegram\nбыл недоступен.',22,MUTED,width=375)
    f.box(540,813,380,44,'#edf3fc');f.text(556,818,'Подробнее об инциденте',21,BLUE)
    f.text(1022,278,'За последний час',25,bold=True)
    f.text(1022,345,'По наблюдениям: 87,5%\nПокрытие периода: 80%\nНаблюдаемый DOWN: 6 мин\nНет наблюдений: 12 мин',22,width=375)
    f.text(1022,560,'Скорость загрузки\nэтой сводкой не измеряется.',22,MUTED,width=375)
    f.box(1020,755,380,44,'#edf3fc');f.text(1036,760,'Сутки · Неделя',21,BLUE)
    f.box(1020,813,380,44,'#edf3fc');f.text(1036,818,'Последние события',21,BLUE)
    f.text(42,921,'Предложение для обсуждения. Названия кнопок, интервалы и состав сводок уточняются до реализации.',20,MUTED)
    f.finish()


if __name__ == '__main__':
    for build in (architecture,samples,coverage,telegram):
        build()
        print(build.__name__+' rendered')

# 사용법: python make_regions.py "법정동코드 전체자료.txt"  ->  regions.json 생성 (index.html과 같은 폴더에 두세요)
# 자료 출처: 행정안전부 법정동코드 전체자료 (공공데이터포털/행정표준코드관리시스템). 인코딩 cp949, 탭 구분.
import sys, json
SHORT = {"서울특별시":"서울","부산광역시":"부산","대구광역시":"대구","인천광역시":"인천","광주광역시":"광주","대전광역시":"대전","울산광역시":"울산","세종특별자치시":"세종","경기도":"경기","강원특별자치도":"강원","강원도":"강원","충청북도":"충북","충청남도":"충남","전북특별자치도":"전북","전라북도":"전북","전라남도":"전남","경상북도":"경북","경상남도":"경남","제주특별자치도":"제주"}
out = {}
for line in open(sys.argv[1], encoding="cp949"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3 or "폐지" in p[2] or p[0] == "법정동코드": continue
    t = p[1].split()
    if t[0] not in SHORT: continue
    s = SHORT[t[0]]; t = t[1:]
    if s == "세종" and len(t) == 1: gu, dong = "세종시", t[0]
    elif len(t) >= 3 and t[0].endswith("시") and t[1].endswith("구"): gu, dong = t[0]+" "+t[1], t[2]
    elif len(t) >= 2: gu, dong = t[0], t[1]
    else: continue
    if dong.endswith("리") and not dong.endswith("동"): continue  # 읍·면 아래 '리'는 제외
    out.setdefault(s, {}).setdefault(gu, [])
    if dong not in out[s][gu]: out[s][gu].append(dong)
json.dump(out, open("regions.json", "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
print("완료:", sum(len(v) for v in out.values()), "개 시·군·구")

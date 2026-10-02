import { useState } from 'react';
import { Circle, SquaresFour, Folder, FileText, HardDrives, Code, DownloadSimple, GearSix, ShieldCheck } from '@phosphor-icons/react';
import './file-demo.css';

const initialFiles = [
  {name:'Application cache',path:'~/Library/Caches/ExampleApp',size:842,kind:'Caches',icon:Folder,selected:true},
  {name:'Build cache',path:'~/Library/Developer/Xcode/DerivedData',size:1240,kind:'Developer',icon:Code,selected:true},
  {name:'Application logs',path:'~/Library/Logs/ExampleApp',size:126,kind:'Logs',icon:FileText,selected:true},
  {name:'Old installer.dmg',path:'~/Downloads/Old installer.dmg',size:1140,kind:'Installers',icon:DownloadSimple,selected:false},
  {name:'Summer film.mov',path:'~/Movies/Summer film.mov',size:2300,kind:'Large files',icon:HardDrives,selected:false},
];
const categories = [
  ['All files', 'All files', SquaresFour], ['Caches', 'Caches', Folder],
  ['Developer', 'Dev', Code], ['Logs', 'Logs', FileText],
  ['Installers', 'Installers', DownloadSimple], ['Large files', 'Large files', HardDrives],
];
const formatSize = n => n >= 1000 ? `${(n / 1000).toFixed(2)} GB` : `${n} MB`;

export function FileDemo({Modal}) {
  const [files,setFiles] = useState(initialFiles);
  const [filter,setFilter] = useState('All files');
  const [review,setReview] = useState(false);
  const selected = files.filter(f=>f.selected);
  const total = selected.reduce((sum,f)=>sum+f.size,0);
  const visibleFiles = files.filter(f=>filter==='All files'||f.kind===filter);

  return <div className="native-demo-group" id="preview">
    <div className="native-demo">
      <div className="native-titlebar">
        <div className="native-window-lights" aria-hidden="true">
          <Circle weight="fill"/><Circle weight="fill"/><Circle weight="fill"/>
        </div>
        <span>SpotlessMac</span>
        <small>Interactive example</small>
      </div>
      <div className="native-window-body">
        <nav className="native-rail" aria-label="Filter example files">
          <img src="/images/app-icon.png" alt="" width="36" height="36"/>
          {categories.map(([value,label,Icon])=><button
            key={value} aria-label={value} aria-pressed={filter===value}
            className={filter===value?'is-active':''} onClick={()=>setFilter(value)}>
            <Icon size={21}/><span>{label}</span>
          </button>)}
          <GearSix className="native-rail-gear" size={19} aria-hidden="true"/>
        </nav>
        <div className="native-workspace">
          <header className="native-scan-header">
            <div><h3>Storage cleanup</h3><p>Choose what you want to remove.</p></div>
            <span className="native-sample">Sample scan</span>
          </header>
          <div className="native-selection-bar">
            <span><ShieldCheck size={16} weight="fill"/>Review before cleaning</span>
            <small>{filter==='All files'?'All files':filter}</small>
          </div>
          <div className="native-file-list" aria-label="Example scan results">
            {visibleFiles.map(f=><label className="native-file" key={f.name}>
              <input type="checkbox" checked={f.selected} onChange={()=>setFiles(current=>current.map(x=>x.name===f.name?{...x,selected:!x.selected}:x))}/>
              <f.icon className={`native-file-icon ${f.kind==='Large files'||f.kind==='Installers'?'needs-review':''}`} size={22} weight="duotone"/>
              <span className="native-file-info"><strong>{f.name}</strong><small title={f.path}>{f.path}</small></span>
              <span className="native-file-size">{formatSize(f.size)}</span>
            </label>)}
          </div>
          <footer className="native-footer">
            <div aria-live="polite"><strong>{formatSize(total)}</strong><small>{selected.length} {selected.length===1?'file':'files'} selected</small></div>
            <button onClick={()=>setReview(true)} disabled={!selected.length}>Review selection</button>
          </footer>
        </div>
      </div>
    </div>
    <p className="native-caption">Illustrative files. Nothing on your Mac is scanned or changed.</p>
    {review&&<Modal title="Your selection, your decision." close={()=>setReview(false)}>
      <p>In Spotless Mac, you review file paths and sizes before confirming. These are example files only.</p>
      <ul className="review-list">{selected.map(f=><li key={f.name}><strong>{f.name}<span>{formatSize(f.size)}</span></strong><code>{f.path}</code></li>)}</ul>
      <p className="notice">Regular files go to Trash. Disk space becomes available after you empty Trash. Docker resources have a separate deletion flow.</p>
      <button className="button" onClick={()=>setReview(false)}>Back to example</button>
    </Modal>}
  </div>;
}

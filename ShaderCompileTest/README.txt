"윈도우에서 gpurt shader 컴파일 성공 여부 확인하는 용도"

0. 이 ShaderCompileTest 폴더를 gpurt 내부에
1. 환경에 맞게 config.txt 수정하기
2. Target Shaders 에 형식에 맞게 추가
e.g) 
BuildParallel:BuildBvh GPURT_BUILD_PARALLEL_ENABLE_RTIP3=1
-> "BuildParallel.hlsl의 진입점(main역할)은 BuildBvh이고, GPURT_BUILD_PARALLEL_ENABLE_RTIP3=1 매크로 추가 정의하겠다."
3. CompileBvhShaders.bat 실행